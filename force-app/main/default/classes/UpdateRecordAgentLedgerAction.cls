/**
 * UpdateRecordAgentLedgerAction
 *
 * Agent action "Update Record (AgentLedger)": changes fields on any record and
 * logs the change, with before and after values, in the same transaction. The
 * agent cannot make the change without it being logged.
 *
 * The update runs with the running user's permissions (object, field and
 * record access). If the log entry cannot be written, the change is rolled
 * back or kept according to the agent's "If Logging Fails" setting
 * (roll back by default in tamper-evident modes).
 */
public with sharing class UpdateRecordAgentLedgerAction {

    public class Request {
        @InvocableVariable(label='Record Id' description='Id of the record to update.' required=true)
        public String recordId;

        @InvocableVariable(label='Field Values' description='The fields to set, as a JSON object of field API names and values, e.g. {"Status": "Escalated", "Priority": "High"}.' required=true)
        public String fieldValues;

        @InvocableVariable(label='Reasoning' description='Why the agent is making this change, in plain language. Shown in the activity log.' required=true)
        public String reasoning;

        @InvocableVariable(label='Agent Id' description='The agent\'s identifier, the same in every AgentLedger action of this agent.' required=true)
        public String agentId;

        @InvocableVariable(label='Summary' description='Optional one-line headline for the log. Generated from the change when blank.' required=false)
        public String summary;

        @InvocableVariable(label='Session Id' description='Optional. The run to log into; the agent\'s open run is used when blank.' required=false)
        public Id sessionId;
    }

    public class Result {
        @InvocableVariable(label='Success') public Boolean success;
        @InvocableVariable(label='Error Message') public String errorMessage;
        @InvocableVariable(label='Changes' description='What changed, e.g. "Status: New → Escalated".') public String changes;
        @InvocableVariable(label='Session Id' description='The run the change was logged in.') public Id sessionId;
        @InvocableVariable(label='Logged' description='False when the change was made but could not be logged.') public Boolean logged;
    }

    @InvocableMethod(
        label='Update Record (AgentLedger)'
        description='Updates fields on a record and logs the change with before and after values in the AgentLedger activity log.'
        category='AgentLedger'
    )
    public static List<Result> execute(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            results.add(updateOne(req));
        }
        return results;
    }

    private static Result updateOne(Request req) {
        Result res = new Result();
        res.logged = false;
        Savepoint sp = Database.setSavepoint();
        List<AgentLedgerRecordSupport.FieldChange> changes = new List<AgentLedgerRecordSupport.FieldChange>();
        AgentLedgerSettings.Resolved settings = AgentLedgerSettings.forAgent(req.agentId);
        SObject before;
        Schema.DescribeSObjectResult d;
        try {
            if (String.isBlank(req.reasoning)) {
                throw new AgentLedgerRecordSupport.RecordException('Reasoning is required.');
            }
            Id recordId = Id.valueOf(AgentAuditRecorder.normalizeId(req.recordId));
            d = recordId.getSObjectType().getDescribe();
            Map<String, Object> values = AgentLedgerRecordSupport.parseFieldValues(req.fieldValues);

            SObject toUpdate = recordId.getSObjectType().newSObject(recordId);
            List<Schema.DescribeFieldResult> fields = new List<Schema.DescribeFieldResult>();
            Set<String> readFields = new Set<String>();
            for (String key : values.keySet()) {
                Schema.DescribeFieldResult fd = AgentLedgerRecordSupport.writableField(d, key, false);
                toUpdate.put(fd.getName(), AgentLedgerRecordSupport.coerce(fd, values.get(key)));
                fields.add(fd);
                readFields.add(fd.getName());
            }
            String nameField = AgentLedgerRecordSupport.nameField(d);
            if (nameField != null) {
                readFields.add(nameField);
            }

            before = AgentLedgerRecordSupport.readRecord(recordId, readFields);
            Database.update(toUpdate, AccessLevel.USER_MODE);
            SObject after = AgentLedgerRecordSupport.readRecord(recordId, readFields);

            for (Schema.DescribeFieldResult fd : fields) {
                Object b = before.get(fd.getName());
                Object a = after.get(fd.getName());
                if (b != a) {
                    changes.add(AgentLedgerRecordSupport.change(settings, d.getName(), fd, b, a));
                }
            }
            res.changes = changes.isEmpty()
                ? 'No change: the fields already had these values.'
                : AgentLedgerRecordSupport.describeChanges(changes);
            res.success = true;
        } catch (Exception e) {
            Database.rollback(sp);
            res.success = false;
            res.errorMessage = e.getMessage();
            return res;
        }

        // Log the change in the same transaction.
        try {
            Id runId = AgentLedgerRuns.resolve(req.sessionId, req.agentId, req.recordId);
            if (runId == null) {
                return res; // AgentLedger is turned off for this agent
            }
            AgentAuditRecorder.EntryInput entry = new AgentAuditRecorder.EntryInput();
            entry.agentId = req.agentId;
            entry.actionType = 'Data_Change';
            entry.captureMethod = 'Recorded_Action';
            entry.reasoning = req.reasoning;
            entry.targetRecordId = req.recordId;
            entry.targetObject = d.getName();
            entry.inputContext = 'Requested: ' + req.fieldValues;
            entry.outputResult = res.changes;
            entry.fieldChanges = System.JSON.serialize(changes);
            String name = AgentLedgerRecordSupport.displayName(before, d);
            entry.summary = AgentLedgerRecordSupport.fit(String.isNotBlank(req.summary)
                ? req.summary
                : (changes.isEmpty() ? 'No change to ' + name : 'Updated ' + name + ': ' + res.changes), 255);
            AgentAuditRecorder.recordEntry(runId, entry);
            res.sessionId = runId;
            res.logged = true;
        } catch (Exception logError) {
            if (settings.rollBackOnLogFailure()) {
                Database.rollback(sp);
                res.success = false;
                res.changes = null;
                res.errorMessage = 'The change was not made because it could not be logged: ' + logError.getMessage();
            } else {
                res.errorMessage = 'The change was made but could not be logged: ' + logError.getMessage();
            }
        }
        return res;
    }
}
