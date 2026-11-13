import { LightningElement } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getSetup from '@salesforce/apex/AgentLedgerSetupController.getSetup';
import saveSetting from '@salesforce/apex/AgentLedgerSetupController.saveSetting';
import setAutoClose from '@salesforce/apex/AgentLedgerSetupController.setAutoClose';
import runAutoCloseNow from '@salesforce/apex/AgentLedgerSetupController.runAutoCloseNow';
import { agentInstructions } from './instructions';

const MODES = [
    { label: 'Activity Log', value: 'Activity_Log' },
    { label: 'Tamper-Evident', value: 'Tamper_Evident' },
    { label: 'Tamper-Evident + Anchored', value: 'Anchored' }
];
const FAILURE = [
    { label: 'Default for the mode', value: '' },
    { label: 'Continue: keep the change', value: 'Continue' },
    { label: 'Roll back the change', value: 'Roll_Back' }
];
const PERMISSION_SETS = [
    { name: 'AgentLedger_Admin', label: 'AgentLedger Admin', note: 'Admins: see every run, open this page.' },
    { name: 'AgentLedger_User', label: 'AgentLedger User', note: 'Everyone who uses agents or owns records the agents work on.' },
    { name: 'AgentLedger_Agent', label: 'AgentLedger Agent', note: 'The user a service agent runs as.' },
    { name: 'AgentLedger_Tamper_Testing', label: 'AgentLedger Tamper Testing', note: 'Testing only. Should be 0 in production.' }
];
const APPLY_DELAY_MS = 5000;
const SETTING_FIELDS = ['developerName', 'agentApiName', 'agentforceAgent', 'enabled', 'mode', 'onLogFailure',
    'autoCloseMinutes', 'storeFieldValues', 'neverStoreFields', 'policyReference', 'policyText'];

/**
 * AgentLedger Setup: org-wide settings, settings per agent, and health.
 */
export default class AgentLedgerSetup extends LightningElement {
    data;
    org;
    selectedAgent;
    agentForm;
    isLoading = true;
    isSaving = false;
    error;

    modeOptions = MODES;
    agentModeOptions = [{ label: 'Org default', value: '' }, ...MODES];
    failureOptions = FAILURE;

    connectedCallback() {
        this.load();
    }

    async load() {
        this.isLoading = true;
        try {
            this.data = await getSetup();
            this.org = { ...this.data.orgDefault };
            if (this.selectedAgent) {
                this.openAgent(this.selectedAgent);
            }
            this.error = undefined;
        } catch (e) {
            this.error = reduceError(e);
        } finally {
            this.isLoading = false;
        }
    }

    get readOnly() {
        return !this.data || !this.data.canEdit;
    }

    get health() {
        return this.data ? this.data.health : {};
    }

    get autoCloseLabel() {
        return this.health.autoCloseScheduled ? 'On (hourly)' : 'Off';
    }

    get permissionRows() {
        const counts = (this.health && this.health.permissionSetUsers) || {};
        return PERMISSION_SETS.map((p) => ({
            ...p,
            users: counts[p.name] || 0,
            warn: p.name === 'AgentLedger_Tamper_Testing' && counts[p.name] > 0
        }));
    }

    get agentRows() {
        if (!this.data) {
            return [];
        }
        const modeLabel = (m) => (MODES.find((x) => x.value === m) || {}).label;
        return this.data.agents.map((a) => ({
            ...a,
            agentId: a.setting ? a.setting.agentApiName : a.apiName,
            status: !a.setting ? 'Org default'
                : a.setting.enabled === false ? 'Turned off'
                    : (modeLabel(a.setting.mode) || 'Org default'),
            selected: this.selectedAgent === a.apiName
        }));
    }

    get hasAgents() {
        return this.data && this.data.agents.length > 0;
    }

    // ── Org default ──

    handleOrgChange(event) {
        const field = event.target.dataset.field;
        const value = event.target.type === 'toggle' || event.target.type === 'checkbox'
            ? event.target.checked : event.detail.value;
        this.org = { ...this.org, [field]: field === 'autoCloseMinutes' ? (value === '' ? null : Number(value)) : value };
    }

    async handleSaveOrg() {
        await this.save({ ...this.org, developerName: 'Org_Default' }, 'Org settings');
    }

    // ── Agents ──

    handleEditAgent(event) {
        this.openAgent(event.currentTarget.dataset.api);
    }

    openAgent(apiName) {
        const agent = this.data.agents.find((a) => a.apiName === apiName);
        if (!agent) {
            return;
        }
        this.selectedAgent = apiName;
        const s = agent.setting || {};
        this.agentForm = {
            developerName: s.developerName || null,
            label: agent.label,
            agentApiName: s.agentApiName || agent.apiName,
            agentforceAgent: agent.apiName,
            enabled: s.enabled !== false,
            mode: s.mode || '',
            onLogFailure: s.onLogFailure || '',
            policyReference: s.policyReference || '',
            policyText: s.policyText || ''
        };
    }

    handleAgentChange(event) {
        const field = event.target.dataset.field;
        const value = event.target.type === 'toggle' || event.target.type === 'checkbox'
            ? event.target.checked : event.detail.value;
        this.agentForm = { ...this.agentForm, [field]: value };
    }

    renderedCallback() {
        // A native textarea shows its value property, which templates cannot bind.
        const box = this.template.querySelector('textarea.instructions');
        if (box && box.value !== this.agentInstructionText) {
            box.value = this.agentInstructionText;
        }
    }

    /** The instruction to add to the agent, from the values in the form (saved or not). */
    get agentInstructionText() {
        return this.agentForm
            ? agentInstructions({ agentId: this.agentForm.agentApiName, policyReference: this.agentForm.policyReference })
            : '';
    }

    async handleCopyInstructions() {
        const text = this.agentInstructionText;
        try {
            await navigator.clipboard.writeText(text);
            this.toast('Instructions copied', 'Paste them as a new instruction in the subagent of this agent.', 'success');
            return;
        } catch (e) {
            // Clipboard API not available here: copy from the selected text instead.
        }
        const box = this.template.querySelector('textarea.instructions');
        box.focus();
        box.select();
        let copied = false;
        try {
            // eslint-disable-next-line @lwc/lwc/no-document-query
            copied = document.execCommand('copy');
        } catch (e) {
            copied = false;
        }
        if (copied) {
            this.toast('Instructions copied', 'Paste them as a new instruction in the subagent of this agent.', 'success');
        } else {
            this.toast('Press Ctrl+C (Cmd+C on a Mac) to copy', 'The instructions are selected.', 'info');
        }
    }

    handleCloseAgent() {
        this.selectedAgent = null;
        this.agentForm = null;
    }

    async handleSaveAgent() {
        await this.save({ ...this.agentForm }, this.agentForm.label);
    }

    // ── Auto-close ──

    async handleAutoCloseToggle(event) {
        try {
            const h = await setAutoClose({ enabled: event.target.checked });
            this.data = { ...this.data, health: h };
            this.toast('Auto-close ' + (h.autoCloseScheduled ? 'on' : 'off'), '', 'success');
        } catch (e) {
            this.toast('Could not change auto-close', reduceError(e), 'error');
        }
    }

    async handleRunNow() {
        try {
            await runAutoCloseNow();
            this.toast('Auto-close started', 'Inactive runs are being closed. Refresh in a minute.', 'success');
        } catch (e) {
            this.toast('Could not start auto-close', reduceError(e), 'error');
        }
    }

    // ── Shared ──

    async save(setting, what) {
        this.isSaving = true;
        try {
            // Send only the fields the server knows.
            const payload = {};
            SETTING_FIELDS.forEach((f) => {
                if (setting[f] !== undefined) {
                    payload[f] = setting[f] === '' ? null : setting[f];
                }
            });
            await saveSetting({ setting: payload });
            this.toast(what + ' saved', 'Changes apply within a few seconds.', 'success');
            // Custom metadata is deployed asynchronously; reload once it has applied.
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            setTimeout(() => this.load(), APPLY_DELAY_MS);
        } catch (e) {
            this.toast('Could not save', reduceError(e), 'error');
        } finally {
            this.isSaving = false;
        }
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}

function reduceError(error) {
    if (error && error.body && error.body.message) {
        return error.body.message;
    }
    return (error && error.message) || 'Unknown error';
}
