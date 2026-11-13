/**
 * AgentLedgerReconciliation
 *
 * A completeness check that does not rely on AgentLedger's own capture: the
 * field changes Salesforce itself recorded in Field History during a run, by
 * the run's user, on the records the run touched, each looked up in the log.
 * A change Salesforce recorded that the log does not have is listed.
 *
 * Only fields with Field History Tracking turned on are covered, and objects
 * without a history table are reported as not tracked. Other changes by the
 * same user during the run (for example their own edit in the UI) are listed
 * too; the reviewer decides. Matching is by record and field.
 */
public without sharing class AgentLedgerReconciliation {

    /** History rows written in the same transaction can be stamped slightly before the run starts. */
    private static final Integer SKEW_SECONDS = 5;

    public class Result {
        @AuraEnabled public Integer recordsChecked = 0;
        @AuraEnabled public Integer historyChanges = 0;
        @AuraEnabled public Integer matched = 0;
        @AuraEnabled public List<Missing> missing = new List<Missing>();
        @AuraEnabled public List<String> notTracked = new List<String>();
        @AuraEnabled public String summary;
    }

    public class Missing {
        @AuraEnabled public String recordId;
        @AuraEnabled public String objectName;
        @AuraEnabled public String field;
        @AuraEnabled public String fieldLabel;
        @AuraEnabled public String before;
        @AuraEnabled public String after;
        @AuraEnabled public DateTime changedAt;
    }

    /** One Field History row, whatever the history object. */
    public class HistoryRow {
        public String recordId;
        public String field;
        public Object oldValue;
        public Object newValue;
        public DateTime createdDate;
        public HistoryRow(String recordId, String field, Object oldValue, Object newValue, DateTime createdDate) {
            this.recordId = recordId;
            this.field = field;
            this.oldValue = oldValue;
            this.newValue = newValue;
            this.createdDate = createdDate;
        }
    }

    /** History rows to use instead of the org's, for tests: history rows cannot be created in tests. */
    @TestVisible
    private static List<HistoryRow> historyForTest;

    public class ReconciliationException extends Exception {}

    @AuraEnabled
    public static Result reconcileRun(Id runId) {
        try {
            return reconcile(runId);
        } catch (ReconciliationException e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @TestVisible
    private static Result reconcile(Id runId) {
        if (runId == null || !AgentLedgerAccess.canViewRun(runId)) {
            throw new ReconciliationException('You do not have access to this agent run.');
        }
        Agent_Audit_Session__c run = [
            SELECT Start_Time__c, End_Time__c, Started_By__c, Related_Record_Id__c, Related_Object__c
            FROM Agent_Audit_Session__c WHERE Id = :runId
        ];

        // The records the run is about or touched, and the fields the log has changes for.
        Map<String, String> objectOf = new Map<String, String>();
        if (String.isNotBlank(run.Related_Record_Id__c) && String.isNotBlank(run.Related_Object__c)) {
            objectOf.put(norm(run.Related_Record_Id__c), run.Related_Object__c);
        }
        Set<String> logged = new Set<String>();
        for (Agent_Audit_Record__c e : [
            SELECT Target_Record_Id__c, Target_Object__c, Field_Changes__c
            FROM Agent_Audit_Record__c WHERE Audit_Session__c = :runId
        ]) {
            if (String.isBlank(e.Target_Record_Id__c) || String.isBlank(e.Target_Object__c)) {
                continue;
            }
            String rec = norm(e.Target_Record_Id__c);
            objectOf.put(rec, e.Target_Object__c);
            if (String.isBlank(e.Field_Changes__c)) {
                continue;
            }
            try {
                for (Object o : (List<Object>) JSON.deserializeUntyped(e.Field_Changes__c)) {
                    String f = (String) ((Map<String, Object>) o).get('field');
                    if (f != null) {
                        logged.add(rec + '|' + f.toLowerCase());
                    }
                }
            } catch (Exception ex) {
                // Not a list of changes: nothing to match against.
            }
        }

        Result result = new Result();
        result.recordsChecked = objectOf.size();
        DateTime fromTime = run.Start_Time__c == null ? null : run.Start_Time__c.addSeconds(-SKEW_SECONDS);
        DateTime toTime = (run.End_Time__c == null ? DateTime.now() : run.End_Time__c).addSeconds(SKEW_SECONDS);

        Map<String, Set<String>> idsByObject = new Map<String, Set<String>>();
        for (String rec : objectOf.keySet()) {
            String obj = objectOf.get(rec);
            if (!idsByObject.containsKey(obj)) {
                idsByObject.put(obj, new Set<String>());
            }
            idsByObject.get(obj).add(rec);
        }

        Set<String> seen = new Set<String>();
        for (String obj : idsByObject.keySet()) {
            Schema.SObjectType type = Schema.getGlobalDescribe().get(obj.toLowerCase());
            List<HistoryRow> rows = history(obj, idsByObject.get(obj), run.Started_By__c, fromTime, toTime);
            if (rows == null) {
                result.notTracked.add(type == null ? obj : type.getDescribe().getLabel());
                continue;
            }
            Map<String, Schema.SObjectField> fields = type == null ? null : type.getDescribe().fields.getMap();
            for (HistoryRow h : rows) {
                if (h.field == null || h.field.equalsIgnoreCase('created')) {
                    continue;
                }
                // Lookups write two rows (Ids and names) for one change.
                String key = norm(h.recordId) + '|' + h.field.toLowerCase();
                if (!seen.add(key + '|' + h.createdDate.getTime())) {
                    continue;
                }
                result.historyChanges++;
                if (logged.contains(key)) {
                    result.matched++;
                    continue;
                }
                Missing m = new Missing();
                m.recordId = norm(h.recordId);
                m.objectName = obj;
                m.field = h.field;
                Schema.SObjectField f = fields == null ? null : fields.get(h.field.toLowerCase());
                m.fieldLabel = f == null ? h.field : f.getDescribe().getLabel();
                Boolean readable = AgentLedgerAccess.canReadField(fields, h.field);
                m.before = readable ? AgentLedgerRecordSupport.format(h.oldValue) : '[hidden]';
                m.after = readable ? AgentLedgerRecordSupport.format(h.newValue) : '[hidden]';
                m.changedAt = h.createdDate;
                result.missing.add(m);
            }
        }

        result.summary = result.historyChanges == 0
            ? 'Salesforce recorded no tracked field changes on these records during this run.'
            : result.missing.isEmpty()
                ? 'All ' + result.historyChanges + ' field change(s) Salesforce recorded during this run are in the log.'
                : result.missing.size() + ' of ' + result.historyChanges
                    + ' field change(s) Salesforce recorded during this run are not in the log.';
        if (!result.notTracked.isEmpty()) {
            result.summary += ' No field history for: ' + String.join(result.notTracked, ', ') + '.';
        }
        return result;
    }

    /**
     * Field History rows for these records, by this user, in the window; null
     * when the object has no history table.
     */
    private static List<HistoryRow> history(String objectName, Set<String> recordIds, Id userId,
                                            DateTime fromTime, DateTime toTime) {
        if (historyForTest != null) {
            List<HistoryRow> out = new List<HistoryRow>();
            for (HistoryRow h : historyForTest) {
                if (recordIds.contains(norm(h.recordId))
                        && (fromTime == null || h.createdDate >= fromTime) && h.createdDate <= toTime) {
                    out.add(h);
                }
            }
            return out;
        }
        String historyObject;
        String parentField;
        if (objectName.endsWithIgnoreCase('__c')) {
            historyObject = objectName.left(objectName.length() - 3) + '__History';
            parentField = 'ParentId';
        } else if (objectName.equalsIgnoreCase('Opportunity')) {
            historyObject = 'OpportunityFieldHistory';
            parentField = 'OpportunityId';
        } else {
            historyObject = objectName + 'History';
            parentField = objectName + 'Id';
        }
        if (!Schema.getGlobalDescribe().containsKey(historyObject.toLowerCase())) {
            return null;
        }
        List<String> ids = new List<String>(recordIds);
        String soql = 'SELECT ' + parentField + ', Field, OldValue, NewValue, CreatedDate FROM ' + historyObject
            + ' WHERE ' + parentField + ' IN :ids AND CreatedById = :userId AND CreatedDate <= :toTime'
            + (fromTime == null ? '' : ' AND CreatedDate >= :fromTime')
            + ' ORDER BY CreatedDate LIMIT 2000';
        List<HistoryRow> out = new List<HistoryRow>();
        for (SObject s : Database.queryWithBinds(soql, new Map<String, Object>{
                'ids' => ids, 'userId' => userId, 'toTime' => toTime, 'fromTime' => fromTime }, AccessLevel.SYSTEM_MODE)) {
            out.add(new HistoryRow(String.valueOf(s.get(parentField)), (String) s.get('Field'), s.get('OldValue'),
                s.get('NewValue'), (DateTime) s.get('CreatedDate')));
        }
        return out;
    }

    /** The 18-character form of an Id, so 15- and 18-character Ids match. */
    private static String norm(String value) {
        try {
            return String.valueOf(Id.valueOf(value));
        } catch (Exception e) {
            return value;
        }
    }
}
