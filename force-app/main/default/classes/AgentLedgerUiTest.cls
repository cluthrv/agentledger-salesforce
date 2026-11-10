/**
 * AgentLedgerUiTest
 *
 * Phase 1 step 6: the record-page timeline, the Agent Activity page and the
 * Setup page controllers.
 */
@isTest
private class AgentLedgerUiTest {

    private static final String AGENT = 'CaseEscalationAgent';

    private static void settings(String mode) {
        AgentLedgerSettings.recordsForTest = (List<AgentLedger_Setting__mdt>) System.JSON.deserialize(
            '[{"DeveloperName":"Org_Default","Enabled__c":true,"Mode__c":"' + mode + '","Store_Field_Values__c":true}]',
            List<AgentLedger_Setting__mdt>.class);
        AgentLedgerPolicy.definitionsForTest = new Map<String, AgentLedgerPolicy.AgentDefinition>();
    }

    private static Case newCase() {
        Case c = new Case(Subject = 'Timeline test', Status = 'New', Priority = 'High', Origin = 'Web');
        insert c;
        return c;
    }

    private static UpdateRecordAgentLedgerAction.Result escalate(Id recordId, Id sessionId) {
        UpdateRecordAgentLedgerAction.Request req = new UpdateRecordAgentLedgerAction.Request();
        req.recordId = recordId;
        req.fieldValues = '{"Status": "Escalated"}';
        req.reasoning = 'High priority and not yet escalated.';
        req.agentId = AGENT;
        req.sessionId = sessionId;
        return UpdateRecordAgentLedgerAction.execute(new List<UpdateRecordAgentLedgerAction.Request>{ req })[0];
    }

    @isTest
    static void theTimelineShowsStepsInPlainLanguage() {
        settings('Tamper_Evident');
        Case c = newCase();
        UpdateRecordAgentLedgerAction.Result res = escalate(c.Id, null);
        AgentAuditRecorder.recordAction(res.sessionId, AGENT, 'Decision', 'High, New', 'Escalate', 'Meets the criteria.\nSecond line.');
        AgentAuditRecorder.sealSession(res.sessionId);

        AgentLedgerTimelineController.Timeline t = AgentLedgerTimelineController.getTimeline(c.Id, 10, null);
        System.assertEquals(1, t.runs.size());
        AgentLedgerTimelineController.RunView run = t.runs[0];
        System.assert(run.aboutThisRecord);
        System.assert(run.tamperEvident);
        System.assertEquals('Tamper-Evident', run.modeLabel);
        System.assertEquals('Closed', run.status);
        System.assertEquals(2, run.entries.size());

        AgentLedgerTimelineController.EntryView change = run.entries[0];
        System.assertEquals('Data change', change.typeLabel);
        System.assert(change.capturedByCode);
        System.assertEquals('Recorded automatically', change.captureLabel);
        System.assertEquals(1, change.fieldChanges.size());
        System.assertEquals('New', change.fieldChanges[0].before);
        System.assertEquals('Escalated', change.fieldChanges[0].after);
        System.assert(change.targetsThisRecord);
        System.assertNotEquals(null, change.hash, 'tamper-evident runs show hashes');

        AgentLedgerTimelineController.EntryView decision = run.entries[1];
        System.assertEquals('Reported by the agent', decision.captureLabel);
        System.assertEquals('Meets the criteria.', decision.summary, 'summary falls back to the first line of the reasoning');

        AgentLedgerTimelineController.RunView verified = AgentLedgerTimelineController.verifyRun(run.runId);
        System.assertEquals('Verified', verified.integrity);
        System.assertNotEquals(null, verified.lastVerifiedAt);
    }

    @isTest
    static void activityLogRunsHideIntegrityDetails() {
        settings('Activity_Log');
        Case c = newCase();
        escalate(c.Id, null);
        AgentLedgerTimelineController.RunView run = AgentLedgerTimelineController.getTimeline(c.Id, null, null).runs[0];
        System.assert(!run.tamperEvident);
        System.assertEquals('Activity Log', run.modeLabel);
        System.assertEquals(null, run.entries[0].hash);
    }

    @isTest
    static void aRunAboutAnotherRecordAppearsWhereItTouched() {
        settings('Activity_Log');
        Case about = newCase();
        Case touched = newCase();
        Id runId = AgentAuditRecorder.startSession(AGENT, about.Id, 'agentforce');
        escalate(touched.Id, runId);

        AgentLedgerTimelineController.Timeline t = AgentLedgerTimelineController.getTimeline(touched.Id, 10, null);
        System.assertEquals(1, t.runs.size());
        System.assert(!t.runs[0].aboutThisRecord);
        System.assert(t.runs[0].entries[0].targetsThisRecord);
        System.assert(!AgentLedgerTimelineController.getTimeline(about.Id, 10, null).runs[0].entries[0].targetsThisRecord);
    }

    @isTest
    static void theTimelinePagesAndChecksAccess() {
        settings('Activity_Log');
        Case c = newCase();
        for (Integer i = 0; i < 3; i++) {
            Id runId = AgentAuditRecorder.startSession('agent-' + i, c.Id, 'agentforce');
            AgentAuditRecorder.recordAction(runId, 'agent-' + i, 'Query', 'in', 'out', 'step');
        }
        AgentLedgerTimelineController.Timeline page = AgentLedgerTimelineController.getTimeline(c.Id, 2, null);
        System.assertEquals(2, page.runs.size());
        System.assert(page.hasMore);
        System.assert(!AgentLedgerTimelineController.getTimeline(c.Id, 5, null).hasMore);
        System.assertEquals(0, AgentLedgerTimelineController.getTimeline(c.Id, 5, DateTime.now().addYears(-1)).runs.size());

        AgentLedgerAccess.readAccessForTest = new Map<Id, Boolean>{ c.Id => false };
        System.assertEquals(0, AgentLedgerTimelineController.getTimeline(c.Id, 5, null).runs.size());
        System.assertEquals(0, AgentLedgerTimelineController.getTimeline('not-an-id', 5, null).runs.size());
    }

    @isTest
    static void theActivityPageFilters() {
        settings('Tamper_Evident');
        Case c = newCase();
        Id open = AgentAuditRecorder.startSession('alpha-agent', c.Id, 'agentforce');
        Id closed = AgentAuditRecorder.startSession('beta-agent', c.Id, 'agentforce');
        AgentAuditRecorder.recordAction(closed, 'beta-agent', 'Query', 'in', 'out', 'step');
        AgentAuditRecorder.sealSession(closed);
        AgentAuditRecorder.verifySession(closed);

        System.assertEquals(2, AgentLedgerActivityController.getRuns(null, null, null, null).size());
        System.assertEquals(open, AgentLedgerActivityController.getRuns('Active', null, null, 10)[0].runId);
        System.assertEquals(closed, AgentLedgerActivityController.getRuns('Closed', 'Verified', null, 10)[0].runId);
        System.assertEquals(1, AgentLedgerActivityController.getRuns(null, 'Not_Checked', null, 10).size());
        System.assertEquals(1, AgentLedgerActivityController.getRuns(null, null, 'alpha', 10).size());
        AgentLedgerActivityController.RunRow row = AgentLedgerActivityController.getRuns(null, null, 'beta', 10)[0];
        System.assertEquals('Closed', row.status);
        System.assertEquals('Verified', row.integrity);
        System.assertEquals(1, row.steps);
        System.assertEquals('Case', row.relatedObject);
    }

    @isTest
    static void theSetupPageReadsAndSavesSettings() {
        AgentLedgerSetupController.recordsForTest = (List<AgentLedger_Setting__mdt>) System.JSON.deserialize(
            '[{"DeveloperName":"Org_Default","Enabled__c":true,"Mode__c":"Tamper_Evident","Auto_Close_Minutes__c":45},' +
            '{"DeveloperName":"Unknown_Agent","Agent_Api_Name__c":"retired-agent","Enabled__c":false}]',
            List<AgentLedger_Setting__mdt>.class);
        AgentLedgerSetupController.SetupData data = AgentLedgerSetupController.getSetup();
        System.assertEquals('Tamper_Evident', data.orgDefault.mode);
        System.assertEquals(45, data.orgDefault.autoCloseMinutes);
        System.assertEquals(1, data.otherAgentSettings.size(), 'a setting for an agent that no longer exists is still shown');
        System.assertNotEquals(null, data.health);
        System.assert(data.health.permissionSetUsers.containsKey('AgentLedger_Admin'));

        if (AgentLedgerSetupController.canEdit()) {
            AgentLedgerSetupController.SettingView org = data.orgDefault;
            org.mode = 'Activity_Log';
            System.assertEquals(null, AgentLedgerSetupController.saveSetting(org), 'tests build the deployment but do not run it');

            AgentLedgerSetupController.SettingView agentSetting = new AgentLedgerSetupController.SettingView();
            agentSetting.agentApiName = 'case-escalation-agent';
            agentSetting.agentforceAgent = AGENT;
            agentSetting.mode = 'Tamper_Evident';
            agentSetting.policyReference = 'Escalation Policy v3';
            AgentLedgerSetupController.saveSetting(agentSetting);

            AgentLedgerSetupController.SettingView noId = new AgentLedgerSetupController.SettingView();
            try {
                AgentLedgerSetupController.saveSetting(noId);
                System.assert(false, 'an agent setting needs an Agent Id');
            } catch (AuraHandledException e) {
                System.assert(true);
            }

            Test.startTest();
            System.assert(AgentLedgerSetupController.setAutoClose(true).autoCloseScheduled);
            System.assert(!AgentLedgerSetupController.setAutoClose(false).autoCloseScheduled);
            System.assertNotEquals(null, AgentLedgerSetupController.runAutoCloseNow());
            Test.stopTest();
        }
    }

    @isTest
    static void agentRecordNamesAreValid() {
        System.assertEquals('case_escalation_agent', AgentLedgerSetupController.developerNameFor(' case-escalation-agent '));
        System.assertEquals('Agent_1st_agent', AgentLedgerSetupController.developerNameFor('1st agent'));
        System.assertEquals(40, AgentLedgerSetupController.developerNameFor('a'.repeat(60)).length());
    }

    @isTest
    static void aFailedSettingsSaveIsLogged() {
        Metadata.DeployResult result = new Metadata.DeployResult();
        result.status = Metadata.DeployStatus.Failed;
        result.errorMessage = 'test failure';
        new AgentLedgerSettingsCallback().handleResult(result, null);
        System.assert(true, 'the callback handles a failure without throwing');
    }
}
