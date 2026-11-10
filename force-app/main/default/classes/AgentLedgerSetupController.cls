/**
 * AgentLedgerSetupController
 *
 * Data and actions for the AgentLedger Setup page: org-wide settings, settings
 * per Agentforce agent, health, and the auto-close job.
 *
 * Settings are custom metadata (AgentLedger_Setting__mdt), saved through the
 * Metadata API, so they deploy between sandboxes and production like any other
 * configuration. Saving needs the Customize Application permission.
 */
public with sharing class AgentLedgerSetupController {

    public class SettingView {
        @AuraEnabled public String developerName;
        @AuraEnabled public String agentApiName;
        @AuraEnabled public String agentforceAgent;
        @AuraEnabled public Boolean enabled;
        @AuraEnabled public String mode;
        @AuraEnabled public String onLogFailure;
        @AuraEnabled public Integer autoCloseMinutes;
        @AuraEnabled public Boolean storeFieldValues;
        @AuraEnabled public String neverStoreFields;
        @AuraEnabled public String policyReference;
        @AuraEnabled public String policyText;
    }

    public class AgentView {
        @AuraEnabled public String label;
        @AuraEnabled public String apiName;
        @AuraEnabled public String kind;
        @AuraEnabled public SettingView setting;
    }

    public class Health {
        @AuraEnabled public Integer totalRuns = 0;
        @AuraEnabled public Integer activeRuns = 0;
        @AuraEnabled public Integer incompleteRuns = 0;
        @AuraEnabled public Integer tamperedRuns = 0;
        @AuraEnabled public Integer snapshots = 0;
        @AuraEnabled public Boolean autoCloseScheduled = false;
        @AuraEnabled public DateTime autoCloseNextRun;
        @AuraEnabled public Map<String, Integer> permissionSetUsers = new Map<String, Integer>();
    }

    public class SetupData {
        @AuraEnabled public Boolean canEdit;
        @AuraEnabled public SettingView orgDefault;
        @AuraEnabled public List<AgentView> agents = new List<AgentView>();
        @AuraEnabled public List<SettingView> otherAgentSettings = new List<SettingView>();
        @AuraEnabled public Health health;
    }

    /** Records to use instead of the org's, for tests. */
    @TestVisible
    private static List<AgentLedger_Setting__mdt> recordsForTest;

    @AuraEnabled
    public static SetupData getSetup() {
        SetupData data = new SetupData();
        data.canEdit = canEdit();
        List<AgentLedger_Setting__mdt> records = recordsForTest != null ? recordsForTest : AgentLedger_Setting__mdt.getAll().values();

        Map<String, SettingView> byAgentKey = new Map<String, SettingView>();
        for (AgentLedger_Setting__mdt rec : records) {
            SettingView v = toView(rec);
            if (rec.DeveloperName == AgentLedgerSettings.ORG_DEFAULT) {
                data.orgDefault = v;
            } else {
                if (String.isNotBlank(rec.Agentforce_Agent__c)) {
                    byAgentKey.put(rec.Agentforce_Agent__c.toLowerCase(), v);
                }
                if (String.isNotBlank(rec.Agent_Api_Name__c) && !byAgentKey.containsKey(rec.Agent_Api_Name__c.toLowerCase())) {
                    byAgentKey.put(rec.Agent_Api_Name__c.toLowerCase(), v);
                }
            }
        }
        if (data.orgDefault == null) {
            data.orgDefault = defaultOrgView();
        }

        Set<SettingView> used = new Set<SettingView>();
        for (BotDefinition bot : [SELECT DeveloperName, MasterLabel, Type FROM BotDefinition ORDER BY MasterLabel]) {
            AgentView a = new AgentView();
            a.label = bot.MasterLabel;
            a.apiName = bot.DeveloperName;
            a.kind = bot.Type == 'InternalCopilot' ? 'Employee agent' : 'Service agent';
            a.setting = byAgentKey.get(bot.DeveloperName.toLowerCase());
            if (a.setting != null) {
                used.add(a.setting);
            }
            data.agents.add(a);
        }
        for (SettingView v : byAgentKey.values()) {
            if (!used.contains(v) && !data.otherAgentSettings.contains(v)) {
                data.otherAgentSettings.add(v);
            }
        }
        data.health = health();
        return data;
    }

    /**
     * Save a setting: the org default (developerName Org_Default) or an agent's.
     * Returns the Metadata API deployment Id; the change applies when it completes.
     */
    @AuraEnabled
    public static Id saveSetting(SettingView setting) {
        requireEditor();
        if (setting == null) {
            throw new AuraHandledException('Nothing to save.');
        }
        Boolean isOrg = setting.developerName == AgentLedgerSettings.ORG_DEFAULT;
        if (!isOrg && String.isBlank(setting.agentApiName)) {
            throw new AuraHandledException('Agent Id is required: the value the agent passes as Agent Id in AgentLedger actions.');
        }
        String devName = isOrg ? AgentLedgerSettings.ORG_DEFAULT
            : (String.isNotBlank(setting.developerName) ? setting.developerName : developerNameFor(setting.agentApiName));

        Metadata.CustomMetadata md = new Metadata.CustomMetadata();
        md.fullName = 'AgentLedger_Setting.' + devName;
        md.label = isOrg ? 'Org Default' : setting.agentApiName.left(40);
        md.protected_x = false;
        addValue(md, 'Enabled__c', setting.enabled != false);
        addValue(md, 'Mode__c', blankToNull(setting.mode));
        addValue(md, 'On_Log_Failure__c', blankToNull(setting.onLogFailure));
        addValue(md, 'Policy_Reference__c', blankToNull(setting.policyReference));
        addValue(md, 'Policy_Text__c', blankToNull(setting.policyText));
        if (isOrg) {
            addValue(md, 'Auto_Close_Minutes__c', setting.autoCloseMinutes);
            addValue(md, 'Store_Field_Values__c', setting.storeFieldValues != false);
            addValue(md, 'Never_Store_Fields__c', blankToNull(setting.neverStoreFields));
        } else {
            addValue(md, 'Agent_Api_Name__c', setting.agentApiName.trim());
            addValue(md, 'Agentforce_Agent__c', blankToNull(setting.agentforceAgent));
        }

        Metadata.DeployContainer container = new Metadata.DeployContainer();
        container.addMetadata(md);
        if (Test.isRunningTest()) {
            return null; // the Metadata API cannot deploy from tests
        }
        return Metadata.Operations.enqueueDeployment(container, new AgentLedgerSettingsCallback());
    }

    /** Turn the hourly auto-close job on or off (off while upgrading AgentLedger). */
    @AuraEnabled
    public static Health setAutoClose(Boolean enabled) {
        requireEditor();
        List<CronTrigger> jobs = [SELECT Id FROM CronTrigger WHERE CronJobDetail.Name = :AgentLedgerAutoClose.JOB_NAME];
        if (enabled == true && jobs.isEmpty()) {
            AgentLedgerAutoClose.scheduleHourly();
        } else if (enabled != true) {
            for (CronTrigger job : jobs) {
                System.abortJob(job.Id);
            }
        }
        return health();
    }

    /** Close inactive runs now. */
    @AuraEnabled
    public static Id runAutoCloseNow() {
        requireEditor();
        return Database.executeBatch(new AgentLedgerAutoClose(), AgentLedgerAutoClose.BATCH_SIZE);
    }

    // ── Helpers ──

    @TestVisible
    private static Boolean canEdit() {
        return [
            SELECT COUNT() FROM PermissionSetAssignment
            WHERE AssigneeId = :UserInfo.getUserId() AND PermissionSet.PermissionsCustomizeApplication = true
        ] > 0;
    }

    private static void requireEditor() {
        if (!canEdit()) {
            throw new AuraHandledException('Changing AgentLedger settings needs the Customize Application permission.');
        }
    }

    private static Health health() {
        Health h = new Health();
        for (AggregateResult ar : [SELECT Status__c s, COUNT(Id) n FROM Agent_Audit_Session__c GROUP BY Status__c]) {
            Integer n = (Integer) ar.get('n');
            String s = (String) ar.get('s');
            h.totalRuns += n;
            if (s == AgentAuditRecorder.STATUS_ACTIVE) {
                h.activeRuns += n;
            } else if (s == AgentAuditRecorder.STATUS_INCOMPLETE) {
                h.incompleteRuns += n;
            }
        }
        h.tamperedRuns = [SELECT COUNT() FROM Agent_Audit_Session__c WHERE Integrity__c = 'Tampered'];
        h.snapshots = [SELECT COUNT() FROM Agent_Instructions_Snapshot__c];
        for (CronTrigger job : [SELECT NextFireTime FROM CronTrigger WHERE CronJobDetail.Name = :AgentLedgerAutoClose.JOB_NAME LIMIT 1]) {
            h.autoCloseScheduled = true;
            h.autoCloseNextRun = job.NextFireTime;
        }
        for (String ps : new List<String>{ 'AgentLedger_Admin', 'AgentLedger_User', 'AgentLedger_Agent', 'AgentLedger_Tamper_Testing' }) {
            h.permissionSetUsers.put(ps, 0);
        }
        for (AggregateResult ar : [
            SELECT PermissionSet.Name ps, COUNT(Id) n FROM PermissionSetAssignment
            WHERE PermissionSet.Name IN ('AgentLedger_Admin', 'AgentLedger_User', 'AgentLedger_Agent', 'AgentLedger_Tamper_Testing')
            GROUP BY PermissionSet.Name
        ]) {
            h.permissionSetUsers.put((String) ar.get('ps'), (Integer) ar.get('n'));
        }
        return h;
    }

    private static SettingView toView(AgentLedger_Setting__mdt rec) {
        SettingView v = new SettingView();
        v.developerName = rec.DeveloperName;
        v.agentApiName = rec.Agent_Api_Name__c;
        v.agentforceAgent = rec.Agentforce_Agent__c;
        v.enabled = rec.Enabled__c;
        v.mode = rec.Mode__c;
        v.onLogFailure = rec.On_Log_Failure__c;
        v.autoCloseMinutes = rec.Auto_Close_Minutes__c == null ? null : rec.Auto_Close_Minutes__c.intValue();
        v.storeFieldValues = rec.Store_Field_Values__c;
        v.neverStoreFields = rec.Never_Store_Fields__c;
        v.policyReference = rec.Policy_Reference__c;
        v.policyText = rec.Policy_Text__c;
        return v;
    }

    private static SettingView defaultOrgView() {
        SettingView v = new SettingView();
        v.developerName = AgentLedgerSettings.ORG_DEFAULT;
        v.enabled = true;
        v.mode = AgentLedgerSettings.MODE_ACTIVITY_LOG;
        v.autoCloseMinutes = 30;
        v.storeFieldValues = true;
        return v;
    }

    /** A valid custom metadata record name for an agent: letters, digits, single underscores, at most 40. */
    @TestVisible
    private static String developerNameFor(String agentApiName) {
        String s = agentApiName.trim().replaceAll('[^A-Za-z0-9]+', '_').replaceAll('^_+|_+$', '');
        if (String.isBlank(s) || !s.left(1).isAlpha()) {
            s = 'Agent_' + s;
        }
        s = s.left(40).replaceAll('_+$', '');
        return s;
    }

    private static void addValue(Metadata.CustomMetadata md, String field, Object value) {
        Metadata.CustomMetadataValue v = new Metadata.CustomMetadataValue();
        v.field = field;
        v.value = value;
        md.values.add(v);
    }

    private static String blankToNull(String s) {
        return String.isBlank(s) ? null : s.trim();
    }
}
