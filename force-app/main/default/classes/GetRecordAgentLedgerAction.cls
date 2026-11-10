/**
 * GetRecordAgentLedgerAction
 *
 * Agent action "Get Record (AgentLedger)": reads fields of any record with the
 * running user's permissions and logs what the agent looked at.
 */
public with sharing class GetRecordAgentLedgerAction {

    public class Request {
        @InvocableVariable(label='Record Id' description='Id of the record to read.' required=true)
        public String recordId;

        @InvocableVariable(label='Fields' description='Optional. Field API names to read, comma-separated, e.g. "Status, Priority, Subject". All accessible fields (up to 100) when blank.' required=false)
        public String fields;

        @InvocableVariable(label='Agent Id' description='The agent\'s identifier, the same in every AgentLedger action of this agent.' required=true)
        public String agentId;

        @InvocableVariable(label='Reasoning' description='Optional. Why the agent is looking at this record.' required=false)
        public String reasoning;

        @InvocableVariable(label='Session Id' description='Optional. The run to log into; the agent\'s open run is used when blank.' required=false)
        public Id sessionId;
    }

    public class Result {
        @InvocableVariable(label='Success') public Boolean success;
        @InvocableVariable(label='Error Message') public String errorMessage;
        @InvocableVariable(label='Record' description='The field values, as a JSON object.') public String recordJson;
        @InvocableVariable(label='Session Id' description='The run the lookup was logged in.') public Id sessionId;
    }

    @InvocableMethod(
        label='Get Record (AgentLedger)'
        description='Reads fields of a record and logs the lookup in the AgentLedger activity log.'
        category='AgentLedger'
    )
    public static List<Result> execute(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            Result res = new Result();
            try {
                Id recordId = Id.valueOf(AgentAuditRecorder.normalizeId(req.recordId));
                Schema.DescribeSObjectResult d = recordId.getSObjectType().getDescribe();

                List<String> fieldNames = new List<String>();
                if (String.isBlank(req.fields)) {
                    fieldNames = AgentLedgerRecordSupport.defaultReadFields(d);
                } else {
                    Map<String, Schema.SObjectField> fieldMap = d.fields.getMap();
                    for (String f : req.fields.split('[,\\s]+')) {
                        if (String.isBlank(f)) {
                            continue;
                        }
                        Schema.SObjectField field = fieldMap.get(f.trim().toLowerCase());
                        if (field == null) {
                            throw new AgentLedgerRecordSupport.RecordException(d.getName() + ' has no field named ' + f.trim() + '.');
                        }
                        fieldNames.add(field.getDescribe().getName());
                    }
                }
                String nameField = AgentLedgerRecordSupport.nameField(d);
                Set<String> toRead = new Set<String>(fieldNames);
                if (nameField != null) {
                    toRead.add(nameField);
                }
                SObject record = AgentLedgerRecordSupport.readRecord(recordId, toRead);

                Map<String, Object> values = new Map<String, Object>();
                for (String f : fieldNames) {
                    values.put(f, AgentLedgerRecordSupport.format(record.get(f)));
                }
                res.recordJson = System.JSON.serialize(values);
                res.success = true;

                Id runId = AgentLedgerRuns.resolve(req.sessionId, req.agentId, req.recordId);
                if (runId != null) {
                    AgentLedgerSettings.Resolved settings = AgentLedgerSettings.forAgent(req.agentId);
                    AgentAuditRecorder.EntryInput entry = new AgentAuditRecorder.EntryInput();
                    entry.agentId = req.agentId;
                    entry.actionType = 'Query';
                    entry.captureMethod = 'Recorded_Action';
                    entry.reasoning = String.isNotBlank(req.reasoning) ? req.reasoning : 'Looked up the record.';
                    entry.targetRecordId = req.recordId;
                    entry.targetObject = d.getName();
                    entry.inputContext = 'Fields: ' + String.join(fieldNames, ', ');
                    entry.outputResult = System.JSON.serialize(
                        AgentLedgerRecordSupport.loggableValues(settings, d.getName(), record, fieldNames));
                    entry.summary = AgentLedgerRecordSupport.fit('Looked up ' + AgentLedgerRecordSupport.displayName(record, d), 255);
                    AgentAuditRecorder.recordEntry(runId, entry);
                    res.sessionId = runId;
                }
            } catch (Exception e) {
                res.success = false;
                res.errorMessage = e.getMessage();
            }
            results.add(res);
        }
        return results;
    }
}
