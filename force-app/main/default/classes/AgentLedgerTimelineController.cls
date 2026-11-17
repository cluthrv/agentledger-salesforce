/**
 * AgentLedgerTimelineController
 *
 * Data for the AgentLedger activity timeline on a record page: the runs about
 * this record or whose steps touched it, newest first, with their entries in
 * plain language.
 *
 * Runs are private, so this reads them without sharing, and only after
 * confirming the user can read the record. Field values in field changes are
 * shown only for fields the user may read.
 */
public without sharing class AgentLedgerTimelineController {

    private static final Integer DEFAULT_PAGE_SIZE = 10;
    private static final Integer MAX_PAGE_SIZE = 50;

    public class Timeline {
        @AuraEnabled public List<RunView> runs = new List<RunView>();
        @AuraEnabled public Boolean hasMore = false;
    }

    public class RunView {
        @AuraEnabled public Id runId;
        @AuraEnabled public String name;
        @AuraEnabled public String agent;
        @AuraEnabled public String agentVersion;
        @AuraEnabled public String policyReference;
        @AuraEnabled public String instructionsHash;
        @AuraEnabled public Id instructionsSnapshotId;
        @AuraEnabled public String startedBy;
        @AuraEnabled public DateTime startTime;
        @AuraEnabled public DateTime endTime;
        @AuraEnabled public String status;
        @AuraEnabled public String modeLabel;
        @AuraEnabled public Boolean tamperEvident;
        @AuraEnabled public String integrity;
        @AuraEnabled public DateTime lastVerifiedAt;
        @AuraEnabled public String fingerprint;
        @AuraEnabled public Integer entryCount;
        @AuraEnabled public Boolean aboutThisRecord;
        @AuraEnabled public List<EntryView> entries = new List<EntryView>();
    }

    public class EntryView {
        @AuraEnabled public Id entryId;
        @AuraEnabled public Integer sequence;
        @AuraEnabled public String type;
        @AuraEnabled public String typeLabel;
        @AuraEnabled public String summary;
        @AuraEnabled public String reasoning;
        @AuraEnabled public String inputContext;
        @AuraEnabled public String outputResult;
        @AuraEnabled public String captureLabel;
        @AuraEnabled public Boolean capturedByCode;
        @AuraEnabled public String targetRecordId;
        @AuraEnabled public String targetObject;
        @AuraEnabled public Boolean targetsThisRecord;
        @AuraEnabled public DateTime timestamp;
        @AuraEnabled public String policyReference;
        @AuraEnabled public String hash;
        @AuraEnabled public List<FieldChangeView> fieldChanges = new List<FieldChangeView>();
        @AuraEnabled public Integer hiddenFieldChanges = 0;
        @AuraEnabled public Boolean detected = false;
    }

    public class FieldChangeView {
        @AuraEnabled public String field;
        @AuraEnabled public String label;
        @AuraEnabled public String before;
        @AuraEnabled public String after;
        @AuraEnabled public Boolean automatic = false;
    }

    /**
     * The runs for a record page, newest first.
     *
     * @param recordId      the record shown on the page
     * @param pageSize      runs per page (default 10, at most 50)
     * @param startedBefore for "Show older": only runs started before this time
     */
    @AuraEnabled
    public static Timeline getTimeline(String recordId, Integer pageSize, DateTime startedBefore) {
        Timeline timeline = new Timeline();
        Id recId;
        try {
            recId = Id.valueOf(recordId);
        } catch (Exception e) {
            return timeline;
        }
        if (!AgentLedgerAccess.canReadRecord(recId)) {
            return timeline;
        }
        Integer size = pageSize == null || pageSize <= 0 ? DEFAULT_PAGE_SIZE : Math.min(pageSize, MAX_PAGE_SIZE);
        DateTime before = startedBefore == null ? DateTime.now().addYears(100) : startedBefore;

        Integer fetch = size + 1;
        String full = String.valueOf(recId);
        Set<String> idForms = new Set<String>{ full, full.left(15) };

        // Runs about this record, and runs with a step that touched it (two
        // queries: SOQL does not combine OR with a sub-select).
        Set<Id> runIds = new Set<Id>();
        for (Agent_Audit_Session__c r : [
            SELECT Id FROM Agent_Audit_Session__c
            WHERE Related_Record_Id__c IN :idForms AND Start_Time__c < :before
            ORDER BY Start_Time__c DESC LIMIT :fetch
        ]) {
            runIds.add(r.Id);
        }
        for (Agent_Audit_Session__c r : [
            SELECT Id FROM Agent_Audit_Session__c
            WHERE Id IN (SELECT Audit_Session__c FROM Agent_Audit_Record__c WHERE Target_Record_Id__c IN :idForms)
              AND Start_Time__c < :before
            ORDER BY Start_Time__c DESC LIMIT :fetch
        ]) {
            runIds.add(r.Id);
        }

        List<Agent_Audit_Session__c> runs = [
            SELECT Id, Name, Agent_Id__c, Agent_Version__c, Policy_Reference__c, Instructions_Hash__c,
                   Started_By__r.Name, Start_Time__c, End_Time__c, Status__c, Mode__c, Integrity__c,
                   Last_Verified_At__c, Merkle_Root__c, Record_Count__c, Related_Record_Id__c
            FROM Agent_Audit_Session__c
            WHERE Id IN :runIds
            ORDER BY Start_Time__c DESC
            LIMIT :fetch
        ];
        if (runs.size() > size) {
            timeline.hasMore = true;
            runs.remove(size);
        }
        if (runs.isEmpty()) {
            return timeline;
        }

        Set<String> instructionHashes = new Set<String>();
        for (Agent_Audit_Session__c r : runs) {
            if (r.Instructions_Hash__c != null) {
                instructionHashes.add(r.Instructions_Hash__c);
            }
        }
        Map<String, Id> snapshotByHash = new Map<String, Id>();
        for (Agent_Instructions_Snapshot__c s : [
            SELECT Id, Instructions_Hash__c FROM Agent_Instructions_Snapshot__c WHERE Instructions_Hash__c IN :instructionHashes
        ]) {
            snapshotByHash.put(s.Instructions_Hash__c, s.Id);
        }

        Map<Id, RunView> views = new Map<Id, RunView>();
        for (Agent_Audit_Session__c r : runs) {
            RunView v = toRunView(r, idForms);
            v.instructionsSnapshotId = snapshotByHash.get(r.Instructions_Hash__c);
            views.put(r.Id, v);
            timeline.runs.add(v);
        }

        Map<Id, String> relatedByRun = new Map<Id, String>();
        for (Agent_Audit_Session__c r : runs) {
            relatedByRun.put(r.Id, r.Related_Record_Id__c);
        }
        List<Agent_Audit_Record__c> entries = [
            SELECT Id, Audit_Session__c, Sequence_Number__c, Action_Type__c, Summary__c, Reasoning__c,
                   Input_Context__c, Output_Result__c, Capture_Method__c, Target_Record_Id__c, Target_Object__c,
                   Action_Timestamp__c, Timestamp_Text__c, Policy_Reference__c, Field_Changes__c, Record_Hash__c
            FROM Agent_Audit_Record__c
            WHERE Audit_Session__c IN :views.keySet()
            ORDER BY Audit_Session__c, Sequence_Number__c ASC
        ];
        // A run can touch several records. Steps on a record the viewer cannot
        // read are shown only as such, with none of their content.
        Set<String> otherRecords = new Set<String>();
        for (Agent_Audit_Record__c e : entries) {
            String rec = AgentLedgerAccess.entryRecord(e.Target_Record_Id__c, relatedByRun.get(e.Audit_Session__c));
            if (rec != null && !idForms.contains(rec)) {
                otherRecords.add(rec);
            }
        }
        Set<String> readable = AgentLedgerAccess.readableRecords(otherRecords);
        for (Agent_Audit_Record__c e : entries) {
            RunView run = views.get(e.Audit_Session__c);
            String rec = AgentLedgerAccess.entryRecord(e.Target_Record_Id__c, relatedByRun.get(e.Audit_Session__c));
            Boolean restricted = rec != null && !idForms.contains(rec) && !readable.contains(rec);
            run.entries.add(restricted ? restrictedEntryView(e) : toEntryView(e, idForms, run.tamperEvident));
        }
        return timeline;
    }

    /** Verify a run from the record page; returns the run with its new result. */
    @AuraEnabled
    public static RunView verifyRun(Id runId) {
        AgentAuditRecorder.verifySession(runId); // checks access, records the result
        Agent_Audit_Session__c r = [
            SELECT Id, Name, Agent_Id__c, Agent_Version__c, Policy_Reference__c, Instructions_Hash__c,
                   Started_By__r.Name, Start_Time__c, End_Time__c, Status__c, Mode__c, Integrity__c,
                   Last_Verified_At__c, Merkle_Root__c, Record_Count__c, Related_Record_Id__c
            FROM Agent_Audit_Session__c WHERE Id = :runId
        ];
        return toRunView(r, new Set<String>());
    }

    // ── Views ──

    private static RunView toRunView(Agent_Audit_Session__c r, Set<String> idForms) {
        RunView v = new RunView();
        v.runId = r.Id;
        v.name = r.Name;
        v.agent = r.Agent_Id__c;
        v.agentVersion = r.Agent_Version__c;
        v.policyReference = r.Policy_Reference__c;
        v.instructionsHash = r.Instructions_Hash__c;
        v.startedBy = r.Started_By__r == null ? null : r.Started_By__r.Name;
        v.startTime = r.Start_Time__c;
        v.endTime = r.End_Time__c;
        v.status = AgentAuditRecorder.isClosed(r.Status__c) && r.Status__c != AgentAuditRecorder.STATUS_INCOMPLETE
            ? AgentAuditRecorder.STATUS_CLOSED : r.Status__c;
        // Runs from before modes existed were tamper-evident.
        v.tamperEvident = r.Mode__c == null || r.Mode__c == AgentLedgerSettings.MODE_TAMPER_EVIDENT
            || r.Mode__c == AgentLedgerSettings.MODE_ANCHORED;
        v.modeLabel = r.Mode__c == AgentLedgerSettings.MODE_ACTIVITY_LOG ? 'Activity Log'
            : r.Mode__c == AgentLedgerSettings.MODE_ANCHORED ? 'Tamper-Evident + Anchored' : 'Tamper-Evident';
        v.integrity = r.Integrity__c;
        v.lastVerifiedAt = r.Last_Verified_At__c;
        v.fingerprint = r.Merkle_Root__c;
        v.entryCount = r.Record_Count__c == null ? 0 : r.Record_Count__c.intValue();
        v.aboutThisRecord = r.Related_Record_Id__c != null && idForms.contains(r.Related_Record_Id__c);
        return v;
    }

    private static final Map<String, String> TYPE_LABELS = new Map<String, String>{
        'Data_Change' => 'Data change', 'Tool_Call' => 'Tool call', 'Human_Response' => 'Human response',
        'Query' => 'Lookup'
    };

    public static final String RESTRICTED_SUMMARY = 'A step on a record you do not have access to';

    /** A step on a record the viewer cannot read: that it happened, and nothing of its content. */
    private static EntryView restrictedEntryView(Agent_Audit_Record__c e) {
        EntryView v = new EntryView();
        v.entryId = e.Id;
        v.sequence = e.Sequence_Number__c == null ? null : e.Sequence_Number__c.intValue();
        v.type = e.Action_Type__c;
        v.typeLabel = TYPE_LABELS.containsKey(e.Action_Type__c) ? TYPE_LABELS.get(e.Action_Type__c) : e.Action_Type__c;
        v.summary = RESTRICTED_SUMMARY;
        v.captureLabel = 'Restricted';
        v.capturedByCode = false;
        v.targetsThisRecord = false;
        v.timestamp = e.Action_Timestamp__c;
        return v;
    }

    private static EntryView toEntryView(Agent_Audit_Record__c e, Set<String> idForms, Boolean tamperEvident) {
        EntryView v = new EntryView();
        v.entryId = e.Id;
        v.sequence = e.Sequence_Number__c == null ? null : e.Sequence_Number__c.intValue();
        v.type = e.Action_Type__c;
        v.typeLabel = TYPE_LABELS.containsKey(e.Action_Type__c) ? TYPE_LABELS.get(e.Action_Type__c) : e.Action_Type__c;
        v.reasoning = e.Reasoning__c;
        v.summary = String.isNotBlank(e.Summary__c) ? e.Summary__c : firstLine(e.Reasoning__c);
        v.inputContext = e.Input_Context__c;
        v.outputResult = readableResult(e.Output_Result__c, fieldMap(e.Target_Object__c));
        v.capturedByCode = e.Capture_Method__c == 'Recorded_Action' || e.Capture_Method__c == 'Agent_Script'
            || e.Capture_Method__c == 'Change_Detector';
        v.detected = e.Capture_Method__c == AgentLedgerChangeDetector.CAPTURE_METHOD;
        v.captureLabel = v.detected ? 'Detected: not logged by the agent'
            : v.capturedByCode ? 'Recorded automatically' : 'Reported by the agent';
        v.targetRecordId = e.Target_Record_Id__c;
        v.targetObject = e.Target_Object__c;
        v.targetsThisRecord = e.Target_Record_Id__c != null && idForms.contains(e.Target_Record_Id__c);
        v.timestamp = e.Action_Timestamp__c;
        v.policyReference = e.Policy_Reference__c;
        v.hash = tamperEvident ? e.Record_Hash__c : null;
        addFieldChanges(v, e);
        if (v.hiddenFieldChanges > 0) {
            // The summary, request and result of a change repeat its values.
            v.summary = 'Changed ' + (String.isBlank(e.Target_Object__c) ? 'a record' : e.Target_Object__c)
                + ', including fields you do not have access to';
            v.inputContext = null;
            v.outputResult = null;
        }
        return v;
    }

    /** Field changes the viewer may see; others are counted, not shown. */
    private static void addFieldChanges(EntryView v, Agent_Audit_Record__c e) {
        if (String.isBlank(e.Field_Changes__c)) {
            return;
        }
        List<Object> raw;
        try {
            raw = (List<Object>) System.JSON.deserializeUntyped(e.Field_Changes__c);
        } catch (Exception ex) {
            return;
        }
        Map<String, Schema.SObjectField> fields = fieldMap(e.Target_Object__c);
        for (Object o : raw) {
            Map<String, Object> c = (Map<String, Object>) o;
            String fieldName = (String) c.get('field');
            if (!AgentLedgerAccess.canReadField(fields, fieldName)) {
                v.hiddenFieldChanges++;
                continue;
            }
            FieldChangeView fc = new FieldChangeView();
            fc.field = fieldName;
            fc.label = (String) c.get('label');
            fc.before = (String) c.get('before');
            fc.after = (String) c.get('after');
            fc.automatic = c.get('automatic') == true;
            v.fieldChanges.add(fc);
        }
    }

    private static Map<String, Schema.SObjectField> fieldMap(String objectName) {
        if (String.isBlank(objectName)) {
            return null;
        }
        Schema.SObjectType t = Schema.getGlobalDescribe().get(objectName.toLowerCase());
        return t == null ? null : t.getDescribe().fields.getMap();
    }

    /**
     * A flat JSON object of field values (a lookup's result) as "Field: value"
     * lines, leaving out fields the viewer cannot read. Anything else as stored.
     */
    @TestVisible
    private static String readableResult(String stored, Map<String, Schema.SObjectField> fields) {
        if (String.isBlank(stored) || !stored.trim().startsWith('{')) {
            return stored;
        }
        Map<String, Object> values;
        try {
            values = (Map<String, Object>) System.JSON.deserializeUntyped(stored);
        } catch (Exception ex) {
            return stored;
        }
        List<String> lines = new List<String>();
        for (String key : values.keySet()) {
            Object value = values.get(key);
            if (value instanceof Map<String, Object> || value instanceof List<Object>) {
                return stored;
            }
            if (!AgentLedgerAccess.canReadField(fields, key)) {
                continue;
            }
            lines.add(key + ': ' + (value == null ? '(blank)' : String.valueOf(value)));
        }
        return lines.isEmpty() ? null : String.join(lines, '\n');
    }

    private static String firstLine(String s) {
        if (String.isBlank(s)) {
            return null;
        }
        String line = s.trim().split('\n')[0];
        return line.length() > 160 ? line.left(159) + '…' : line;
    }
}
