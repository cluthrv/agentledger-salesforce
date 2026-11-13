/**
 * AgentLedgerChangeDetectorTest
 *
 * Capture layer 3: changes an agent makes without an AgentLedger action are
 * logged by the detector triggers. Tests cannot run with the INVOCABLE_ACTION
 * quiddity, so agentActionForTest stands in for it.
 */
@isTest
private class AgentLedgerChangeDetectorTest {

    private static final String AGENT = 'CaseEscalationAgent';

    private static void settings(String extraOrgFields) {
        AgentLedgerSettings.recordsForTest = (List<AgentLedger_Setting__mdt>) System.JSON.deserialize(
            '[{"DeveloperName":"Org_Default","Enabled__c":true,"Mode__c":"Tamper_Evident","Store_Field_Values__c":true'
            + extraOrgFields + '}]', List<AgentLedger_Setting__mdt>.class);
        AgentLedgerPolicy.definitionsForTest = new Map<String, AgentLedgerPolicy.AgentDefinition>();
    }

    private static Case newCase() {
        AgentLedgerChangeDetector.agentActionForTest = false; // set up as a person
        Case c = new Case(Subject = 'Detector test', Status = 'New', Priority = 'High', Origin = 'Web');
        insert c;
        return c;
    }

    private static List<Agent_Audit_Record__c> detected() {
        return [SELECT Audit_Session__c, Audit_Session__r.Agent_Id__c, Action_Type__c, Summary__c, Field_Changes__c,
                       Target_Record_Id__c, Capture_Method__c
                FROM Agent_Audit_Record__c WHERE Capture_Method__c = :AgentLedgerChangeDetector.CAPTURE_METHOD
                ORDER BY Sequence_Number__c];
    }

    @isTest
    static void anAgentChangeOutsideAgentLedgerIsLogged() {
        settings('');
        Case c = newCase();
        AgentLedgerChangeDetector.agentActionForTest = true; // an agent, through the standard Update Record action
        update new Case(Id = c.Id, Status = 'Escalated');

        List<Agent_Audit_Record__c> es = detected();
        System.assertEquals(1, es.size());
        System.assertEquals('Data_Change', es[0].Action_Type__c);
        System.assertEquals(c.Id, es[0].Target_Record_Id__c);
        System.assert(es[0].Summary__c.contains('outside AgentLedger') && es[0].Summary__c.contains('New → Escalated'), es[0].Summary__c);
        System.assert(es[0].Field_Changes__c.contains('"after":"Escalated"'), es[0].Field_Changes__c);
        System.assertEquals(AgentLedgerChangeDetector.UNIDENTIFIED_AGENT, es[0].Audit_Session__r.Agent_Id__c,
            'no open run: a run for an unidentified agent');
        System.assert(AgentAuditRecorder.verifySession(es[0].Audit_Session__c).valid);

        AgentLedgerTimelineController.EntryView v = AgentLedgerTimelineController.getTimeline(c.Id, 10, null).runs[0].entries[0];
        System.assert(v.detected);
        System.assertEquals('Detected: not logged by the agent', v.captureLabel);
    }

    @isTest
    static void aDetectedChangeJoinsTheAgentsOpenRun() {
        settings('');
        Case c = newCase();
        AgentLedgerChangeDetector.agentActionForTest = true;
        GetRecordAgentLedgerAction.Request g = new GetRecordAgentLedgerAction.Request();
        g.agentId = AGENT; g.recordId = c.Id; g.fields = 'Status';
        Id runId = GetRecordAgentLedgerAction.execute(new List<GetRecordAgentLedgerAction.Request>{ g })[0].sessionId;

        update new Case(Id = c.Id, Status = 'Escalated');

        List<Agent_Audit_Record__c> es = detected();
        System.assertEquals(1, es.size());
        System.assertEquals(runId, es[0].Audit_Session__c, 'logged in the agent\'s open run on this Case');
        System.assertEquals(AGENT, es[0].Audit_Session__r.Agent_Id__c);
        System.assertEquals(2, [SELECT Record_Count__c FROM Agent_Audit_Session__c WHERE Id = :runId].Record_Count__c);
    }

    @isTest
    static void fieldsSalesforceSetsItselfAreLeftOut() {
        settings('');
        AgentLedgerChangeDetector.agentActionForTest = false;
        Opportunity o = new Opportunity(Name = 'Detector', StageName = 'Prospecting', CloseDate = Date.today().addDays(30), Amount = 50000);
        insert o;
        AgentLedgerChangeDetector.agentActionForTest = true;
        update new Opportunity(Id = o.Id, StageName = 'Needs Analysis');

        String changes = detected()[0].Field_Changes__c;
        System.assert(changes.contains('Needs Analysis'), changes);
        System.assert(!changes.containsIgnoreCase('LastStageChangeDate'), 'set by Salesforce, not the agent: ' + changes);
        System.assert(AgentLedgerChangeDetector.maintainedBySalesforce(Opportunity.LastStageChangeDate.getDescribe()));
        System.assert(!AgentLedgerChangeDetector.maintainedBySalesforce(Opportunity.StageName.getDescribe()));
        System.assert(!AgentLedgerChangeDetector.maintainedBySalesforce(Opportunity.Amount.getDescribe()));
    }

    @isTest
    static void anUnidentifiedRunIsAboutOneRecord() {
        settings('');
        Case a = newCase();
        Case b = newCase();
        AgentLedgerChangeDetector.agentActionForTest = true;
        update new Case(Id = a.Id, Status = 'Working');
        update new Case(Id = b.Id, Status = 'Working');
        update new Case(Id = a.Id, Status = 'Escalated');

        List<Agent_Audit_Record__c> es = detected();
        System.assertEquals(3, es.size());
        System.assertNotEquals(es[0].Audit_Session__c, es[1].Audit_Session__c, 'Case B gets its own run, not the run for Case A');
        Set<Id> runs = new Set<Id>();
        for (Agent_Audit_Record__c e : es) {
            runs.add(e.Audit_Session__c);
        }
        System.assertEquals(2, runs.size(), 'the second change to Case A joins the run for Case A');
    }

    @isTest
    static void recordedActionsAreNotLoggedTwice() {
        settings('');
        Case c = newCase();
        AgentLedgerChangeDetector.agentActionForTest = true;
        UpdateRecordAgentLedgerAction.Request u = new UpdateRecordAgentLedgerAction.Request();
        u.agentId = AGENT; u.recordId = c.Id; u.fieldValues = '{"Status": "Escalated"}'; u.reasoning = 'qualifies';
        UpdateRecordAgentLedgerAction.Result r = UpdateRecordAgentLedgerAction.execute(new List<UpdateRecordAgentLedgerAction.Request>{ u })[0];
        System.assert(r.success && r.logged);
        System.assertEquals(0, detected().size(), 'the recorded action logged it, with reasoning');
        System.assertEquals(1, [SELECT COUNT() FROM Agent_Audit_Record__c]);

        CreateRecordAgentLedgerAction.Request cr = new CreateRecordAgentLedgerAction.Request();
        cr.agentId = AGENT; cr.objectApiName = 'Case'; cr.fieldValues = '{"Subject":"Follow-up","Origin":"Web"}';
        cr.reasoning = 'follow-up'; cr.sessionId = r.sessionId;
        System.assert(CreateRecordAgentLedgerAction.execute(new List<CreateRecordAgentLedgerAction.Request>{ cr })[0].logged);
        System.assertEquals(0, detected().size());
    }

    @isTest
    static void peopleAreNotLogged() {
        settings('');
        Case c = newCase();
        update new Case(Id = c.Id, Status = 'Escalated'); // agentActionForTest is false: a person
        delete c;
        System.assertEquals(0, [SELECT COUNT() FROM Agent_Audit_Record__c]);
    }

    @isTest
    static void createsAndDeletesAreLogged() {
        settings('');
        AgentLedgerChangeDetector.agentActionForTest = true;
        Account a = new Account(Name = 'Detected account', Industry = 'Banking');
        insert a;
        delete a;
        List<Agent_Audit_Record__c> es = detected();
        System.assertEquals(2, es.size());
        System.assertEquals('Create', es[0].Action_Type__c);
        System.assert(es[0].Field_Changes__c.contains('Banking'), es[0].Field_Changes__c);
        System.assertEquals('Delete', es[1].Action_Type__c);
        System.assertEquals(es[0].Audit_Session__c, es[1].Audit_Session__c, 'the same open run');
    }

    @isTest
    static void onlyWatchedObjects() {
        settings(',"Watched_Objects__c":"Opportunity\\nLead"');
        Case c = newCase();
        AgentLedgerChangeDetector.agentActionForTest = true;
        update new Case(Id = c.Id, Status = 'Escalated');
        System.assertEquals(0, detected().size(), 'Case is not watched');
        insert new Lead(LastName = 'Watched', Company = 'Acme');
        System.assertEquals(1, detected().size(), 'Lead is watched');
    }

    @isTest
    static void nothingWhenAgentLedgerIsOff() {
        AgentLedgerSettings.recordsForTest = (List<AgentLedger_Setting__mdt>) System.JSON.deserialize(
            '[{"DeveloperName":"Org_Default","Enabled__c":false}]', List<AgentLedger_Setting__mdt>.class);
        AgentLedgerChangeDetector.agentActionForTest = true;
        insert new Account(Name = 'Off');
        System.assertEquals(0, [SELECT COUNT() FROM Agent_Audit_Record__c]);
    }

    @isTest
    static void bulkChangesAreSummarizedPastTheLimit() {
        settings('');
        AgentLedgerChangeDetector.agentActionForTest = false;
        List<Case> cases = new List<Case>();
        for (Integer i = 0; i < 25; i++) {
            cases.add(new Case(Subject = 'Bulk ' + i, Status = 'New', Origin = 'Web'));
        }
        insert cases;
        for (Case c : cases) {
            c.Status = 'Working';
        }
        AgentLedgerChangeDetector.agentActionForTest = true;
        update cases;
        List<Agent_Audit_Record__c> es = detected();
        System.assertEquals(AgentLedgerChangeDetector.MAX_ROWS_PER_TRANSACTION + 1, es.size());
        System.assert(es[es.size() - 1].Summary__c.startsWith('Changed 5 more'), es[es.size() - 1].Summary__c);
    }

    @isTest
    static void aChangeThatCannotBeLoggedIsRefusedInTamperEvidentMode() {
        settings('');
        Case c = newCase();
        AgentLedgerChangeDetector.agentActionForTest = true;
        AgentLedgerChangeDetector.failLoggingForTest = true;
        Boolean refused = false;
        try {
            update new Case(Id = c.Id, Status = 'Escalated');
        } catch (DmlException e) {
            refused = e.getMessage().contains('AgentLedger could not log this change');
        }
        System.assert(refused, 'Tamper-Evident rolls back changes that cannot be logged');
        System.assertEquals('New', [SELECT Status FROM Case WHERE Id = :c.Id].Status);
    }

    @isTest
    static void aChangeThatCannotBeLoggedGoesThroughInActivityLogMode() {
        AgentLedgerSettings.recordsForTest = (List<AgentLedger_Setting__mdt>) System.JSON.deserialize(
            '[{"DeveloperName":"Org_Default","Enabled__c":true,"Mode__c":"Activity_Log","Store_Field_Values__c":true}]',
            List<AgentLedger_Setting__mdt>.class);
        AgentLedgerPolicy.definitionsForTest = new Map<String, AgentLedgerPolicy.AgentDefinition>();
        Case c = newCase();
        AgentLedgerChangeDetector.agentActionForTest = true;
        AgentLedgerChangeDetector.failLoggingForTest = true;
        update new Case(Id = c.Id, Status = 'Escalated');
        System.assertEquals('Escalated', [SELECT Status FROM Case WHERE Id = :c.Id].Status);
    }

    @isTest
    static void everyShippedObjectIsWatched() {
        settings('');
        AgentLedgerChangeDetector.agentActionForTest = true;
        Account a = new Account(Name = 'Watched');
        insert a;
        insert new Contact(LastName = 'Watched', AccountId = a.Id);
        insert new Lead(LastName = 'Watched', Company = 'Acme');
        insert new Opportunity(Name = 'Watched', StageName = 'Prospecting', CloseDate = Date.today().addDays(30), AccountId = a.Id);
        insert new Case(Subject = 'Watched', Origin = 'Web');
        Set<String> objects = new Set<String>();
        for (Agent_Audit_Record__c e : [SELECT Target_Object__c FROM Agent_Audit_Record__c WHERE Capture_Method__c = :AgentLedgerChangeDetector.CAPTURE_METHOD]) {
            objects.add(e.Target_Object__c);
        }
        System.assertEquals(new Set<String>{ 'Account', 'Contact', 'Lead', 'Opportunity', 'Case' }, objects);
    }

    @isTest
    static void theQuiddityDecidesOutsideTests() {
        AgentLedgerChangeDetector.agentActionForTest = null;
        System.assert(!AgentLedgerChangeDetector.isActionRequest(), 'a test run is not an action request');
    }

    @isTest
    static void theAgentRuntimesFunctionCallIsAnAgentAction() {
        String host = 'https://acme.my.salesforce.com';
        System.assert(AgentLedgerChangeDetector.isAgentFunctionCall(host + '/services/data/v68.0/support/functions/172gK00000WFySr'));
        System.assert(AgentLedgerChangeDetector.isAgentFunctionCall('/services/data/v65.0/support/functions/x'));
        System.assert(!AgentLedgerChangeDetector.isAgentFunctionCall(host + '/services/data/v68.0/sobjects/Case/500gK00001VKEkd'), 'a person through the API');
        System.assert(!AgentLedgerChangeDetector.isAgentFunctionCall(host + '/services/data/v65.0/actions/custom/flow/My_Flow'), 'an integration running a Flow');
        System.assert(!AgentLedgerChangeDetector.isAgentFunctionCall(host + '/services/apexrest/support/functions/x'), 'a custom REST endpoint');
        System.assert(!AgentLedgerChangeDetector.isAgentFunctionCall(host + '/aura?r=1'), 'the Lightning UI');
        System.assert(!AgentLedgerChangeDetector.isAgentFunctionCall(null));
    }
}
