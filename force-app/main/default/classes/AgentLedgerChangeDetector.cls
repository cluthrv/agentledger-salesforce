/**
 * AgentLedgerChangeDetector
 *
 * Capture layer 3: logs record changes an agent made without an AgentLedger
 * action, for example through the standard Update Record action or a Flow
 * action, so a change cannot escape the log by taking another path.
 *
 * Apex has no "agent" flag. What it does show (spike S1 and a live test,
 * November 2026), with the agent driven through preview:
 *   - an Apex action run by an agent has the request quiddity INVOCABLE_ACTION;
 *   - a Flow action run by an agent is SYNCHRONOUS, like a person's API call,
 *     but its request is the agent runtime's call to
 *     /services/data/vNN.N/support/functions/<action>;
 *   - a person's change through the UI or API, and a Flow called through the
 *     Actions REST API (/actions/custom/flow/...), are SYNCHRONOUS on other
 *     paths, so people and integrations are not flagged.
 * AgentLedger's own recorded actions mark their changes
 * (AgentLedgerGuard.beginRecordedChange) and are skipped here: they already
 * logged them, with the agent's reasoning.
 *
 * A detected change goes into the running user's open run for that record,
 * or their most recent open run, or a new run for "Unidentified agent". It is
 * labelled Change Detector, so the timeline shows it was not reported.
 *
 * Triggers ship for Account, Contact, Lead, Opportunity and Case. For another
 * object, add a one-line trigger:
 *
 *   trigger MyObjectAgentLedger on My_Object__c (after insert, after update, after delete) {
 *       AgentLedgerChangeDetector.handle();
 *   }
 *
 * Org default "Watched objects" limits detection to the objects listed; empty
 * means every object with a detector trigger.
 */
public without sharing class AgentLedgerChangeDetector {

    public static final String UNIDENTIFIED_AGENT = 'Unidentified agent';
    public static final String CAPTURE_METHOD = 'Change_Detector';
    /** Rows logged one by one; the rest of a bulk change is summarized in one entry. */
    @TestVisible
    private static final Integer MAX_ROWS_PER_TRANSACTION = 20;

    /** Answers to use instead of the request quiddity, for tests. */
    @TestVisible
    private static Boolean agentActionForTest;

    /** Makes logging fail, for tests of what happens to the change. */
    @TestVisible
    private static Boolean failLoggingForTest = false;

    private static Boolean running = false;
    private static Integer rowsLogged = 0;

    /** Fields that change on every save and say nothing about what the agent did. */
    private static final Set<String> SYSTEM_FIELDS = new Set<String>{
        'id', 'createddate', 'createdbyid', 'lastmodifieddate', 'lastmodifiedbyid', 'systemmodstamp',
        'lastvieweddate', 'lastreferenceddate', 'lastactivitydate', 'isdeleted'
    };

    /** Whether this transaction is running an action (agents' actions run this way). */
    public static Boolean isActionRequest() {
        if (agentActionForTest != null) {
            return agentActionForTest;
        }
        Quiddity q = Request.getCurrent().getQuiddity();
        if (q == Quiddity.INVOCABLE_ACTION) {
            return true;
        }
        if (q != Quiddity.SYNCHRONOUS) {
            return false;
        }
        String url = requestUrl();
        System.debug(LoggingLevel.FINE, 'AgentLedger detector: ' + q + ' ' + url);
        return isAgentFunctionCall(url);
    }

    /** The agent runtime runs an action through /services/data/vNN.N/support/functions/. */
    @TestVisible
    private static Boolean isAgentFunctionCall(String url) {
        return url != null && Pattern.matches('(?i)^(https?://[^/]+)?/services/data/v\\d+\\.\\d+/support/functions/.*', url);
    }

    private static String requestUrl() {
        try {
            System.Url u = System.Url.getCurrentRequestUrl();
            return u == null ? null : u.toExternalForm();
        } catch (Exception e) {
            return null;
        }
    }

    /** For a trigger: after insert, after update, after delete. */
    public static void handle() {
        handle(Trigger.new, Trigger.oldMap, Trigger.operationType);
    }

    public static void handle(List<SObject> newRows, Map<Id, SObject> oldMap, System.TriggerOperation op) {
        if (running || AgentLedgerGuard.isRecordedChange() || AgentLedgerGuard.isLedgerWrite() || !isActionRequest()) {
            return;
        }
        List<SObject> rows = op == System.TriggerOperation.AFTER_DELETE ? oldMap.values() : newRows;
        if (rows == null || rows.isEmpty()) {
            return;
        }
        Schema.DescribeSObjectResult d = rows[0].getSObjectType().getDescribe();
        AgentLedgerSettings.Resolved org = AgentLedgerSettings.orgDefault();
        if (!org.enabled || !watched(org, d.getName())) {
            return;
        }
        running = true;
        try {
            List<SObject> summarized = new List<SObject>();
            for (SObject row : rows) {
                if (rowsLogged < MAX_ROWS_PER_TRANSACTION) {
                    logRow(row, oldMap == null ? null : oldMap.get(row.Id), op, d);
                    rowsLogged++;
                } else {
                    summarized.add(row);
                }
            }
            if (!summarized.isEmpty()) {
                logBulk(summarized, op, d);
            }
        } finally {
            running = false;
        }
    }

    private static Boolean watched(AgentLedgerSettings.Resolved org, String objectName) {
        if (org.watchedObjects.isEmpty()) {
            return true;
        }
        for (String w : org.watchedObjects) {
            if (w.equalsIgnoreCase(objectName)) {
                return true;
            }
        }
        return false;
    }

    private static void logRow(SObject row, SObject old, System.TriggerOperation op, Schema.DescribeSObjectResult d) {
        Id runId;
        AgentLedgerSettings.Resolved settings;
        try {
            Agent_Audit_Session__c run = openRun(row.Id);
            String agentId = run == null ? UNIDENTIFIED_AGENT : run.Agent_Id__c;
            settings = AgentLedgerSettings.forAgent(agentId);
            if (!settings.enabled) {
                return;
            }
            List<AgentLedgerRecordSupport.FieldChange> changes = changes(row, old, op, d, settings);
            if (op == System.TriggerOperation.AFTER_UPDATE && changes.isEmpty()) {
                return;
            }
            if (failLoggingForTest) {
                throw new AgentLedgerRecordSupport.RecordException('forced for a test');
            }
            runId = run != null ? run.Id : AgentAuditRecorder.startSession(agentId, String.valueOf(row.Id), 'agentforce');
            if (runId == null) {
                return;
            }

            String name = AgentLedgerRecordSupport.displayName(row, d);
            String described = AgentLedgerRecordSupport.describeChanges(changes);
            AgentAuditRecorder.EntryInput entry = new AgentAuditRecorder.EntryInput();
            entry.agentId = agentId;
            entry.captureMethod = CAPTURE_METHOD;
            entry.targetRecordId = row.Id;
            entry.targetObject = d.getName();
            entry.fieldChanges = changes.isEmpty() ? null : JSON.serialize(changes);
            entry.outputResult = String.isBlank(described) ? null : described;
            entry.reasoning = 'Detected by AgentLedger: an action changed this record without an AgentLedger action, '
                + 'so the agent did not log it or give a reason.';
            if (op == System.TriggerOperation.AFTER_INSERT) {
                entry.actionType = 'Create';
                entry.summary = 'Created ' + name + ' outside AgentLedger';
            } else if (op == System.TriggerOperation.AFTER_DELETE) {
                entry.actionType = 'Delete';
                entry.summary = 'Deleted ' + name + ' outside AgentLedger';
            } else {
                entry.actionType = 'Data_Change';
                entry.summary = 'Changed ' + name + ' outside AgentLedger: ' + described;
            }
            entry.summary = AgentLedgerRecordSupport.fit(entry.summary, 255);
            AgentAuditRecorder.recordEntry(runId, entry);
        } catch (Exception e) {
            // A backstop must not break the agent, unless the org asked for
            // changes that cannot be logged to be refused.
            if (settings != null && settings.rollBackOnLogFailure()) {
                row.addError('AgentLedger could not log this change, so it was not made: ' + e.getMessage());
            }
        }
    }

    /** One entry for the rows of a bulk change beyond MAX_ROWS_PER_TRANSACTION. */
    private static void logBulk(List<SObject> rows, System.TriggerOperation op, Schema.DescribeSObjectResult d) {
        try {
            Agent_Audit_Session__c run = openRun(null);
            String agentId = run == null ? UNIDENTIFIED_AGENT : run.Agent_Id__c;
            if (!AgentLedgerSettings.forAgent(agentId).enabled) {
                return;
            }
            Id runId = run != null ? run.Id : AgentAuditRecorder.startSession(agentId, null, 'agentforce');
            List<String> ids = new List<String>();
            for (SObject row : rows) {
                ids.add(row.Id);
            }
            String verb = op == System.TriggerOperation.AFTER_INSERT ? 'Created'
                : op == System.TriggerOperation.AFTER_DELETE ? 'Deleted' : 'Changed';
            AgentAuditRecorder.EntryInput entry = new AgentAuditRecorder.EntryInput();
            entry.agentId = agentId;
            entry.captureMethod = CAPTURE_METHOD;
            entry.actionType = 'Data_Change';
            entry.targetObject = d.getName();
            entry.summary = AgentLedgerRecordSupport.fit(verb + ' ' + rows.size() + ' more ' + d.getLabelPlural() + ' outside AgentLedger', 255);
            entry.inputContext = AgentLedgerRecordSupport.fit(String.join(ids, ', '), 32000);
            entry.reasoning = 'Detected by AgentLedger: a bulk change by an action; the first '
                + MAX_ROWS_PER_TRANSACTION + ' records are logged one by one, these together.';
            AgentAuditRecorder.recordEntry(runId, entry);
        } catch (Exception e) {
            // Best effort for the summary; the individual entries were attempted above.
        }
    }

    /**
     * The running user's open run: for this record if there is one, else their
     * most recent agent run (an agent's conversation can touch other records),
     * within the auto-close time. A run for an unidentified agent is about one
     * record only, so other records' changes never join it.
     */
    private static Agent_Audit_Session__c openRun(Id recordId) {
        DateTime activeSince = DateTime.now().addMinutes(-AgentLedgerSettings.orgDefault().autoCloseMinutes);
        Id me = UserInfo.getUserId();
        if (recordId != null) {
            String full = String.valueOf(recordId);
            List<String> forms = new List<String>{ full, full.left(15) };
            List<Agent_Audit_Session__c> forRecord = [
                SELECT Id, Agent_Id__c FROM Agent_Audit_Session__c
                WHERE Status__c = :AgentAuditRecorder.STATUS_ACTIVE AND Started_By__c = :me
                  AND Related_Record_Id__c IN :forms AND Last_Activity__c >= :activeSince
                ORDER BY Last_Activity__c DESC LIMIT 1
            ];
            if (!forRecord.isEmpty()) {
                return forRecord[0];
            }
        }
        List<Agent_Audit_Session__c> latest = [
            SELECT Id, Agent_Id__c FROM Agent_Audit_Session__c
            WHERE Status__c = :AgentAuditRecorder.STATUS_ACTIVE AND Started_By__c = :me
              AND Last_Activity__c >= :activeSince AND Agent_Id__c != :UNIDENTIFIED_AGENT
            ORDER BY Last_Activity__c DESC LIMIT 1
        ];
        return latest.isEmpty() ? null : latest[0];
    }

    /**
     * Fields only Salesforce sets (for example Opportunity Last Stage Change
     * Date): nobody can create or edit them, or be given permission to. They
     * follow from the agent's change and would only repeat it.
     */
    @TestVisible
    private static Boolean maintainedBySalesforce(Schema.DescribeFieldResult fd) {
        return !fd.isCreateable() && !fd.isUpdateable() && !fd.isPermissionable();
    }

    /** What changed: changed fields on update, set fields on insert, nothing on delete. */
    private static List<AgentLedgerRecordSupport.FieldChange> changes(SObject row, SObject old,
            System.TriggerOperation op, Schema.DescribeSObjectResult d, AgentLedgerSettings.Resolved settings) {
        List<AgentLedgerRecordSupport.FieldChange> out = new List<AgentLedgerRecordSupport.FieldChange>();
        if (op == System.TriggerOperation.AFTER_DELETE) {
            return out;
        }
        Map<String, Schema.SObjectField> fields = d.fields.getMap();
        for (String name : row.getPopulatedFieldsAsMap().keySet()) {
            if (SYSTEM_FIELDS.contains(name.toLowerCase())) {
                continue;
            }
            Object after = row.get(name);
            Object before = old == null ? null : old.get(name);
            if (op == System.TriggerOperation.AFTER_INSERT ? after == null : before == after) {
                continue;
            }
            Schema.SObjectField f = fields.get(name.toLowerCase());
            if (f == null) {
                continue;
            }
            Schema.DescribeFieldResult fd = f.getDescribe();
            if (fd.isCalculated() || fd.isAutoNumber() || maintainedBySalesforce(fd)) {
                continue;
            }
            out.add(AgentLedgerRecordSupport.change(settings, d.getName(), fd, before, after));
        }
        return out;
    }
}
