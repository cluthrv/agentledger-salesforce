/**
 * The agent-user scenario of the hardening suite. A Platform-licence user
 * cannot run anonymous Apex, so this runs as that user with System.runAs,
 * which applies the user's own record access and, through the actions'
 * USER_MODE operations, their object and field permissions.
 *
 * Finds the agent user by last name ("Hardening agent", created by
 * hardening/setup.mjs). Test-only metadata; not part of the package.
 */
@isTest
private class HardeningAgentUserTest {

    private static User agentUser() {
        return [SELECT Id FROM User WHERE LastName = 'Hardening agent' AND IsActive = true LIMIT 1];
    }

    @isTest
    static void theAgentUserWorksOnlyThroughItsOwnAccess() {
        Hardening_Item__c adminItem = new Hardening_Item__c(Name = 'Admin only', Status__c = 'Private');
        insert adminItem;
        User agent = agentUser();

        Id runId;
        Id itemId;
        System.runAs(agent) {
            CreateRecordAgentLedgerAction.Request c = new CreateRecordAgentLedgerAction.Request();
            c.agentId = 'HardenTE'; c.objectApiName = 'Hardening_Item__c';
            c.fieldValues = '{"Name":"Agent item","Amount__c":3}'; c.reasoning = 'agent creates';
            CreateRecordAgentLedgerAction.Result created =
                CreateRecordAgentLedgerAction.execute(new List<CreateRecordAgentLedgerAction.Request>{ c })[0];
            System.assert(created.success && created.logged, 'agent creates its own record: ' + created);
            runId = created.sessionId;
            itemId = created.recordId;

            UpdateRecordAgentLedgerAction.Request u = new UpdateRecordAgentLedgerAction.Request();
            u.agentId = 'HardenTE'; u.recordId = itemId; u.sessionId = runId;
            u.fieldValues = '{"Status__c":"Agent done"}'; u.reasoning = 'agent updates';
            UpdateRecordAgentLedgerAction.Result own =
                UpdateRecordAgentLedgerAction.execute(new List<UpdateRecordAgentLedgerAction.Request>{ u })[0];
            System.assert(own.success && own.logged, 'agent updates its own record: ' + own);

            UpdateRecordAgentLedgerAction.Request x = new UpdateRecordAgentLedgerAction.Request();
            x.agentId = 'HardenTE'; x.recordId = adminItem.Id;
            x.fieldValues = '{"Status__c":"Hijacked"}'; x.reasoning = 'agent reaches';
            UpdateRecordAgentLedgerAction.Result reach =
                UpdateRecordAgentLedgerAction.execute(new List<UpdateRecordAgentLedgerAction.Request>{ x })[0];
            System.assert(!reach.success, 'agent cannot update a record it has no access to');

            GetRecordAgentLedgerAction.Request g = new GetRecordAgentLedgerAction.Request();
            g.agentId = 'HardenTE'; g.recordId = adminItem.Id; g.fields = 'Name';
            GetRecordAgentLedgerAction.Result read =
                GetRecordAgentLedgerAction.execute(new List<GetRecordAgentLedgerAction.Request>{ g })[0];
            System.assert(!read.success, 'agent cannot read a record it has no access to');

            SealAgentLedgerSessionAction.Request s = new SealAgentLedgerSessionAction.Request();
            s.sessionId = runId;
            System.assert(SealAgentLedgerSessionAction.execute(new List<SealAgentLedgerSessionAction.Request>{ s })[0].success,
                'agent seals its run');
        }

        System.assertEquals('Private', [SELECT Status__c FROM Hardening_Item__c WHERE Id = :adminItem.Id].Status__c);
        Agent_Audit_Session__c run = [SELECT OwnerId, Started_By__c, Record_Count__c, Mode__c FROM Agent_Audit_Session__c WHERE Id = :runId];
        System.assertEquals(agent.Id, run.OwnerId, 'the run belongs to the agent user');
        System.assertEquals(agent.Id, run.Started_By__c);
        System.assertEquals(2, run.Record_Count__c, 'create and update; nothing for the refused attempts');
        System.assertEquals('Tamper_Evident', run.Mode__c);
        System.assert(AgentAuditRecorder.verifySession(runId).valid, 'the agent user\'s run verifies');
    }
}
