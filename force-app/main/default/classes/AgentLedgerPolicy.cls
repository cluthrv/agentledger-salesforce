/**
 * AgentLedgerPolicy
 *
 * Captures, by code, what an agent was acting under when a run starts:
 *
 *   - Agent Version: the Agentforce agent and its active version.
 *   - Instructions Hash: SHA-256 of every subagent's label, description, scope
 *     and instructions, read from the agent's definition. The text itself is
 *     kept once per distinct version in Agent_Instructions_Snapshot__c, so an
 *     investigator can later read exactly what was in force.
 *   - Policy Reference and Policy Hash: from the agent's AgentLedger Setting
 *     (or passed by the agent), for policies that live outside the agent.
 *
 * Runs and entries carry these values, and entry hashes cover them, so they
 * cannot be swapped afterwards. Capture never blocks a run: if the agent's
 * definition cannot be read, the fields stay blank.
 */
public inherited sharing class AgentLedgerPolicy {

    public static final String INSTRUCTIONS_TAG = 'agentledger/agent-instructions/v1\n';
    public static final String POLICY_TAG = 'agentledger/policy/v1\n';

    public class Captured {
        public String agentVersion;
        public String instructionsHash;
        public String policyReference;
        public String policyHash;
    }

    /** Agent definitions read in this transaction, by agent API name. */
    private static Map<String, AgentDefinition> cache = new Map<String, AgentDefinition>();

    /** Definitions to use instead of the org's, for tests. */
    @TestVisible
    private static Map<String, AgentDefinition> definitionsForTest;

    @TestVisible
    private class AgentDefinition {
        public String version;
        public String content;
        public String agentName;
    }

    /**
     * What the agent identified by agentId is acting under.
     *
     * @param agentId          the Agent Id passed to AgentLedger
     * @param policyReference  a policy reference passed by the agent; overrides the setting's
     */
    public static Captured capture(String agentId, String policyReference) {
        Captured c = new Captured();
        AgentLedgerSettings.Resolved settings = AgentLedgerSettings.forAgent(agentId);

        c.policyReference = String.isNotBlank(policyReference) ? policyReference : settings.policyReference;
        if (String.isNotBlank(settings.policyText)) {
            c.policyHash = HashChainService.sha256(POLICY_TAG + settings.policyText);
        }

        String agentName = String.isNotBlank(settings.agentforceAgent) ? settings.agentforceAgent : agentId;
        AgentDefinition def = definition(agentName);
        if (def != null) {
            c.agentVersion = def.version;
            c.instructionsHash = HashChainService.sha256(INSTRUCTIONS_TAG + def.content);
            keepSnapshot(c.instructionsHash, def);
        }
        return c;
    }

    private static AgentDefinition definition(String agentName) {
        if (String.isBlank(agentName)) {
            return null;
        }
        String key = agentName.trim();
        if (definitionsForTest != null) {
            return definitionsForTest.get(key);
        }
        if (cache.containsKey(key)) {
            return cache.get(key);
        }
        AgentDefinition def = null;
        try {
            def = readDefinition(key);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'AgentLedger could not read agent ' + key + ': ' + e.getMessage());
        }
        cache.put(key, def);
        return def;
    }

    /** The agent's version and its subagents' instructions as canonical JSON, or null if no such agent. */
    private static AgentDefinition readDefinition(String agentName) {
        List<GenAiPlannerDefinition> planners = [
            SELECT Id, DeveloperName, LinkedBotVersionId
            FROM GenAiPlannerDefinition WHERE DeveloperName = :agentName LIMIT 1
        ];
        if (planners.isEmpty()) {
            return null;
        }
        GenAiPlannerDefinition planner = planners[0];

        String version = agentName;
        if (planner.LinkedBotVersionId != null) {
            List<BotVersion> versions = [SELECT VersionNumber, Status FROM BotVersion WHERE Id = :planner.LinkedBotVersionId];
            if (!versions.isEmpty()) {
                version = agentName + ' v' + versions[0].VersionNumber + ' (' + versions[0].Status + ')';
            }
        }

        // The agent's subagents, through the planner-to-subagent junction (this
        // also covers subagents added from the Asset Library).
        Set<Id> pluginIds = new Set<Id>();
        for (GenAiPlannerFunctionDef link : [SELECT Plugin FROM GenAiPlannerFunctionDef WHERE PlannerId = :planner.Id]) {
            try {
                pluginIds.add(Id.valueOf(link.Plugin));
            } catch (Exception e) {
                // not a subagent reference
            }
        }

        Map<String, Schema.SObjectField> pluginFields = Schema.SObjectType.GenAiPluginDefinition.fields.getMap();
        Boolean hasDescription = pluginFields.containsKey('description');
        Boolean hasScope = pluginFields.containsKey('scope');
        String pluginQuery = 'SELECT Id, DeveloperName, MasterLabel'
            + (hasDescription ? ', Description' : '') + (hasScope ? ', Scope' : '')
            + ' FROM GenAiPluginDefinition WHERE Id IN :pluginIds ORDER BY DeveloperName';
        List<SObject> plugins = Database.queryWithBinds(pluginQuery, new Map<String, Object>{ 'pluginIds' => pluginIds }, AccessLevel.SYSTEM_MODE);

        Map<Id, List<Object>> instructionsByPlugin = new Map<Id, List<Object>>();
        for (SObject p : plugins) {
            instructionsByPlugin.put((Id) p.get('Id'), new List<Object>());
        }
        for (GenAiPluginInstructionDef ins : [
            SELECT DeveloperName, Description, GenAiPluginDefinitionId
            FROM GenAiPluginInstructionDef
            WHERE GenAiPluginDefinitionId IN :instructionsByPlugin.keySet()
            ORDER BY DeveloperName
        ]) {
            instructionsByPlugin.get(ins.GenAiPluginDefinitionId).add(new Map<String, Object>{
                'name' => ins.DeveloperName,
                'text' => ins.Description
            });
        }

        List<Map<String, Object>> subagents = new List<Map<String, Object>>();
        for (SObject p : plugins) {
            subagents.add(subagent(
                (String) p.get('DeveloperName'),
                (String) p.get('MasterLabel'),
                hasDescription ? (String) p.get('Description') : null,
                hasScope ? (String) p.get('Scope') : null,
                instructionsByPlugin.get((Id) p.get('Id'))));
        }
        return buildDefinition(agentName, version, subagents);
    }

    /** One subagent as it appears in the instructions document. */
    @TestVisible
    private static Map<String, Object> subagent(String name, String label, String description, String scope, List<Object> instructions) {
        Map<String, Object> sub = new Map<String, Object>{
            'name' => name,
            'label' => label,
            'instructions' => instructions == null ? new List<Object>() : instructions
        };
        if (description != null) {
            sub.put('description', description);
        }
        if (scope != null) {
            sub.put('scope', scope);
        }
        return sub;
    }

    /** The instructions document for an agent version: canonical JSON, so its hash is stable. */
    @TestVisible
    private static AgentDefinition buildDefinition(String agentName, String version, List<Map<String, Object>> subagents) {
        AgentDefinition def = new AgentDefinition();
        def.agentName = agentName;
        def.version = version;
        def.content = AgentLedgerCanonical.serialize(new Map<String, Object>{
            'agent' => agentName,
            'version' => version,
            'subagents' => subagents
        });
        return def;
    }

    /** Keep the instruction text once per distinct hash. */
    private static void keepSnapshot(String hash, AgentDefinition def) {
        if ([SELECT COUNT() FROM Agent_Instructions_Snapshot__c WHERE Instructions_Hash__c = :hash] > 0) {
            return;
        }
        AgentLedgerGuard.beginLedgerWrite();
        try {
            Database.insert(new Agent_Instructions_Snapshot__c(
                Instructions_Hash__c = hash,
                Agent_Name__c = AgentLedgerRecordSupport.fit(def.agentName, 255),
                Agent_Version__c = AgentLedgerRecordSupport.fit(def.version, 120),
                Content__c = def.content.left(131072),
                Captured_At__c = DateTime.now()
            ), false); // a concurrent run may have inserted the same version
        } finally {
            AgentLedgerGuard.endLedgerWrite();
        }
    }
}
