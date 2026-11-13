/**
 * CreateRecordAgentLedgerAction
 *
 * Agent action "Create Record (AgentLedger)": creates a record of any object
 * with the running user's permissions and logs it, with its field values, in
 * the same transaction. If the entry cannot be written, the record is rolled
 * back or kept according to the agent's "If Logging Fails" setting.
 */
public with sharing class CreateRecordAgentLedgerAction {

    public class Request {
        @InvocableVariable(label='Object' description='API name of the object, e.g. Task or Case.' required=true)
        public String objectApiName;

        @InvocableVariable(label='Field Values' description='The fields to set, as a JSON object of field API names and values, e.g. {"Subject": "Call the customer", "WhatId": "006..."}.' required=true)
        public String fieldValues;

        @InvocableVariable(label='Reasoning' description='Why the agent is creating this record, in plain language. Shown in the activity log.' required=true)
        public String reasoning;

        @InvocableVariable(label='Agent Id' description='The agent\'s identifier, the same in every AgentLedger action of this agent.' required=true)
        public String agentId;

        @InvocableVariable(label='Related Record Id' description='Optional. The record this work is about (e.g. the Opportunity a Task is for), so the log appears on its page.' required=false)
        public String relatedRecordId;

        @InvocableVariable(label='Summary' description='Optional one-line headline for the log.' required=false)
        public String summary;

        @InvocableVariable(label='Session Id' description='Optional. The run to log into; the agent\'s open run is used when blank.' required=false)
        public Id sessionId;
    }

    public class Result {
        @InvocableVariable(label='Success') public Boolean success;
        @InvocableVariable(label='Error Message') public String errorMessage;
        @InvocableVariable(label='Record Id' description='Id of the new record.') public Id recordId;
        @InvocableVariable(label='Session Id' description='The run the creation was logged in.') public Id sessionId;
        @InvocableVariable(label='Logged' description='False when the record was created but could not be logged.') public Boolean logged;
    }

    @InvocableMethod(
        label='Create Record (AgentLedger)'
        description='Creates a record and logs it, with its field values, in the AgentLedger activity log.'
        category='AgentLedger'
    )
    public static List<Result> execute(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            results.add(createOne(req));
        }
        return results;
    }

    private static Result createOne(Request req) {
        Result res = new Result();
        res.logged = false;
        Savepoint sp = Database.setSavepoint();
        AgentLedgerSettings.Resolved settings = AgentLedgerSettings.forAgent(req.agentId);
        Schema.DescribeSObjectResult d;
        SObject created;
        List<AgentLedgerRecordSupport.FieldChange> written = new List<AgentLedgerRecordSupport.FieldChange>();
        try {
            if (String.isBlank(req.reasoning)) {
                throw new AgentLedgerRecordSupport.RecordException('Reasoning is required.');
            }
            Schema.SObjectType type = String.isBlank(req.objectApiName) ? null : Schema.getGlobalDescribe().get(req.objectApiName.trim().toLowerCase());
            if (type == null) {
                throw new AgentLedgerRecordSupport.RecordException('There is no object named ' + req.objectApiName + '.');
            }
            d = type.getDescribe();
            Map<String, Object> values = AgentLedgerRecordSupport.parseFieldValues(req.fieldValues);
            SObject record = type.newSObject();
            List<Schema.DescribeFieldResult> fields = new List<Schema.DescribeFieldResult>();
            for (String key : values.keySet()) {
                Schema.DescribeFieldResult fd = AgentLedgerRecordSupport.writableField(d, key, true);
                record.put(fd.getName(), AgentLedgerRecordSupport.coerce(fd, values.get(key)));
                fields.add(fd);
            }
            AgentLedgerGuard.beginRecordedChange();
            try {
                Database.insert(record, AccessLevel.USER_MODE);
            } finally {
                AgentLedgerGuard.endRecordedChange();
            }
            Set<String> readFields = new Set<String>();
            for (Schema.DescribeFieldResult fd : fields) {
                readFields.add(fd.getName());
            }
            String nameField = AgentLedgerRecordSupport.nameField(d);
            if (nameField != null) {
                readFields.add(nameField);
            }
            created = AgentLedgerRecordSupport.readRecord(record.Id, readFields);
            for (Schema.DescribeFieldResult fd : fields) {
                written.add(AgentLedgerRecordSupport.change(settings, d.getName(), fd, null, created.get(fd.getName())));
            }
            res.recordId = record.Id;
            res.success = true;
        } catch (Exception e) {
            Database.rollback(sp);
            res.success = false;
            res.errorMessage = e.getMessage();
            return res;
        }

        try {
            String related = String.isNotBlank(req.relatedRecordId) ? req.relatedRecordId : String.valueOf(res.recordId);
            Id runId = AgentLedgerRuns.resolve(req.sessionId, req.agentId, related);
            if (runId == null) {
                return res; // AgentLedger is turned off for this agent
            }
            AgentAuditRecorder.EntryInput entry = new AgentAuditRecorder.EntryInput();
            entry.agentId = req.agentId;
            entry.actionType = 'Create';
            entry.captureMethod = 'Recorded_Action';
            entry.reasoning = req.reasoning;
            entry.targetRecordId = res.recordId;
            entry.targetObject = d.getName();
            entry.inputContext = 'Requested: ' + req.fieldValues;
            entry.outputResult = AgentLedgerRecordSupport.describeChanges(written);
            entry.fieldChanges = System.JSON.serialize(written);
            entry.summary = AgentLedgerRecordSupport.fit(String.isNotBlank(req.summary)
                ? req.summary
                : 'Created ' + AgentLedgerRecordSupport.displayName(created, d), 255);
            AgentAuditRecorder.recordEntry(runId, entry);
            res.sessionId = runId;
            res.logged = true;
        } catch (Exception logError) {
            if (settings.rollBackOnLogFailure()) {
                Database.rollback(sp);
                res.success = false;
                res.recordId = null;
                res.errorMessage = 'The record was not created because it could not be logged: ' + logError.getMessage();
            } else {
                res.errorMessage = 'The record was created but could not be logged: ' + logError.getMessage();
            }
        }
        return res;
    }
}
