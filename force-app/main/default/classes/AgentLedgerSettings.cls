/**
 * AgentLedgerSettings
 *
 * The effective AgentLedger settings for an agent: its own
 * AgentLedger_Setting__mdt record (matched on Agent API Name, case-insensitive)
 * over the Org_Default record, over built-in defaults. Org-wide settings
 * (capture, privacy, retention, anchoring) come from Org_Default only.
 *
 * Custom metadata is read with getAll(), which uses no SOQL queries.
 */
public with sharing class AgentLedgerSettings {

    public static final String ORG_DEFAULT = 'Org_Default';
    public static final String MODE_ACTIVITY_LOG = 'Activity_Log';
    public static final String MODE_TAMPER_EVIDENT = 'Tamper_Evident';
    public static final String MODE_ANCHORED = 'Anchored';
    public static final String ON_FAILURE_CONTINUE = 'Continue';
    public static final String ON_FAILURE_ROLL_BACK = 'Roll_Back';
    private static final Integer DEFAULT_AUTO_CLOSE_MINUTES = 30;

    /** Records to use instead of the org's, for tests. */
    @TestVisible
    private static List<AgentLedger_Setting__mdt> recordsForTest;

    public class Resolved {
        public Boolean enabled = true;
        public String mode = MODE_ACTIVITY_LOG;
        public String onLogFailure;
        public Integer autoCloseMinutes = DEFAULT_AUTO_CLOSE_MINUTES;
        public Boolean storeFieldValues = true;
        public Set<String> neverStoreFields = new Set<String>();
        public Integer retentionDays;
        public Set<String> watchedObjects = new Set<String>();
        public String anchorProvider = 'None';
        public String anchorNamedCredential;
        public String agentforceAgent;
        public String policyReference;
        public String policyText;

        public Boolean isTamperEvident() {
            return mode == MODE_TAMPER_EVIDENT || mode == MODE_ANCHORED;
        }

        /** Roll back a recorded action's change when its entry cannot be written. */
        public Boolean rollBackOnLogFailure() {
            if (onLogFailure == ON_FAILURE_ROLL_BACK) {
                return true;
            }
            if (onLogFailure == ON_FAILURE_CONTINUE) {
                return false;
            }
            return isTamperEvident();
        }
    }

    /** Settings for an agent, identified by the Agent Id it passes to AgentLedger. */
    public static Resolved forAgent(String agentId) {
        Resolved r = orgDefault();
        AgentLedger_Setting__mdt agentRecord = findAgentRecord(agentId);
        if (agentRecord != null) {
            r.enabled = agentRecord.Enabled__c;
            if (String.isNotBlank(agentRecord.Mode__c)) {
                r.mode = agentRecord.Mode__c;
            }
            if (String.isNotBlank(agentRecord.On_Log_Failure__c)) {
                r.onLogFailure = agentRecord.On_Log_Failure__c;
            }
            r.agentforceAgent = agentRecord.Agentforce_Agent__c;
            if (String.isNotBlank(agentRecord.Policy_Reference__c)) {
                r.policyReference = agentRecord.Policy_Reference__c;
            }
            if (String.isNotBlank(agentRecord.Policy_Text__c)) {
                r.policyText = agentRecord.Policy_Text__c;
            }
        }
        return r;
    }

    /** The org-wide settings: Org_Default over built-in defaults. */
    public static Resolved orgDefault() {
        Resolved r = new Resolved();
        AgentLedger_Setting__mdt org = findOrgDefault();
        if (org == null) {
            return r;
        }
        r.enabled = org.Enabled__c;
        if (String.isNotBlank(org.Mode__c)) {
            r.mode = org.Mode__c;
        }
        r.onLogFailure = org.On_Log_Failure__c;
        if (org.Auto_Close_Minutes__c != null && org.Auto_Close_Minutes__c > 0) {
            r.autoCloseMinutes = org.Auto_Close_Minutes__c.intValue();
        }
        r.storeFieldValues = org.Store_Field_Values__c;
        r.neverStoreFields = parseList(org.Never_Store_Fields__c);
        r.retentionDays = org.Retention_Days__c == null ? null : org.Retention_Days__c.intValue();
        r.watchedObjects = parseList(org.Watched_Objects__c);
        if (String.isNotBlank(org.Anchor_Provider__c)) {
            r.anchorProvider = org.Anchor_Provider__c;
        }
        r.anchorNamedCredential = org.Anchor_Named_Credential__c;
        r.policyReference = org.Policy_Reference__c;
        r.policyText = org.Policy_Text__c;
        return r;
    }

    private static List<AgentLedger_Setting__mdt> records() {
        return recordsForTest != null ? recordsForTest : AgentLedger_Setting__mdt.getAll().values();
    }

    private static AgentLedger_Setting__mdt findOrgDefault() {
        for (AgentLedger_Setting__mdt rec : records()) {
            if (rec.DeveloperName == ORG_DEFAULT) {
                return rec;
            }
        }
        return null;
    }

    private static AgentLedger_Setting__mdt findAgentRecord(String agentId) {
        if (String.isBlank(agentId)) {
            return null;
        }
        String key = agentId.trim().toLowerCase();
        for (AgentLedger_Setting__mdt rec : records()) {
            if (rec.DeveloperName != ORG_DEFAULT && String.isNotBlank(rec.Agent_Api_Name__c)
                && rec.Agent_Api_Name__c.trim().toLowerCase() == key) {
                return rec;
            }
        }
        return null;
    }

    /** A set from a comma- or newline-separated list, trimmed, blanks dropped. */
    @TestVisible
    private static Set<String> parseList(String value) {
        Set<String> out = new Set<String>();
        if (String.isBlank(value)) {
            return out;
        }
        for (String part : value.split('[,\\n\\r]+')) {
            if (String.isNotBlank(part)) {
                out.add(part.trim());
            }
        }
        return out;
    }
}
