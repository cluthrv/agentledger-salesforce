/**
 * The AgentLedger instruction an admin adds to an agent's subagent, next to the
 * agent's own instructions. Built from the agent's settings, so it can be
 * pasted without editing. One line per rule: rich-text instruction editors turn
 * every line break into a new paragraph, so a rule must never wrap.
 */
export function agentInstructions({ agentId, policyReference }) {
    const id = (agentId || '').trim() || '<Agent Id>';
    const policy = (policyReference || '').trim();
    const policyRule = policy
        ? ` Put "${policy}" in Policy Reference.`
        : ' If a named policy applies, put its name in Policy Reference.';
    return [
        `AgentLedger activity log. Follow these rules in addition to your other instructions. Use Agent Id "${id}" in every AgentLedger action, and pass the Session Id returned by the first AgentLedger action to every later AgentLedger action.`,
        '- To read a record, use "Get Record (AgentLedger)".',
        '- To change a record, use ONLY "Update Record (AgentLedger)"; to create one, use ONLY "Create Record (AgentLedger)". Always include your reasoning.',
        '- Whenever you check a rule or criterion, call "Record Agent Action" with Action Type "Validation": the result and the actual value in Output Result, why in Reasoning, and the record\'s Id as Related Record Id.',
        '- When you reach a decision or recommendation, call "Record Agent Action" with Action Type "Decision" or "Recommendation": the outcome in Output Result and why in Reasoning.' + policyRule,
        '- When you hand off to a person or escalate, call "Record Agent Action" with Action Type "Escalation" saying to whom and why.',
        '- When you have finished the task, call "Seal AgentLedger Session" before your final reply.'
    ].join('\n');
}
