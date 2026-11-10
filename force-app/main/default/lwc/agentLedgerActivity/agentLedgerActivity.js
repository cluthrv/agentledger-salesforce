import { LightningElement } from 'lwc';
import getRuns from '@salesforce/apex/AgentLedgerActivityController.getRuns';

const COLUMNS = [
    { label: 'Run', fieldName: 'runUrl', type: 'url', typeAttributes: { label: { fieldName: 'name' } }, initialWidth: 110 },
    { label: 'Agent', fieldName: 'agent' },
    { label: 'Status', fieldName: 'status', initialWidth: 110 },
    { label: 'Integrity', fieldName: 'integrity', initialWidth: 120 },
    { label: 'Mode', fieldName: 'mode', initialWidth: 140 },
    { label: 'Steps', fieldName: 'steps', type: 'number', initialWidth: 80 },
    { label: 'About', fieldName: 'relatedUrl', type: 'url', typeAttributes: { label: { fieldName: 'relatedLabel' } } },
    { label: 'Started by', fieldName: 'startedBy' },
    {
        label: 'Started', fieldName: 'startTime', type: 'date',
        typeAttributes: { year: 'numeric', month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' }
    }
];

const STATUS_OPTIONS = [
    { label: 'All statuses', value: '' },
    { label: 'Open', value: 'Active' },
    { label: 'Closed', value: 'Closed' },
    { label: 'Incomplete (auto-closed)', value: 'Incomplete' }
];
const INTEGRITY_OPTIONS = [
    { label: 'Any integrity', value: '' },
    { label: 'Verified', value: 'Verified' },
    { label: 'Tampered', value: 'Tampered' },
    { label: 'Not checked', value: 'Not_Checked' }
];

/**
 * Agent Activity: recent AgentLedger runs across the org.
 */
export default class AgentLedgerActivity extends LightningElement {
    columns = COLUMNS;
    statusOptions = STATUS_OPTIONS;
    integrityOptions = INTEGRITY_OPTIONS;
    status = '';
    integrity = '';
    agent = '';
    rows = [];
    isLoading = false;
    error;

    connectedCallback() {
        this.load();
    }

    get count() {
        return this.rows.length;
    }

    async load() {
        this.isLoading = true;
        try {
            const runs = await getRuns({ status: this.status, integrity: this.integrity, agent: this.agent, maxRows: 200 });
            this.rows = runs.map((r) => ({
                ...r,
                runUrl: '/lightning/r/Agent_Audit_Session__c/' + r.runId + '/view',
                relatedUrl: r.relatedRecordId ? '/lightning/r/' + r.relatedRecordId + '/view' : null,
                relatedLabel: r.relatedRecordId ? (r.relatedObject || 'Record') + ' ' + r.relatedRecordId : ''
            }));
            this.error = undefined;
        } catch (e) {
            this.error = (e && e.body && e.body.message) || 'Could not load runs';
        } finally {
            this.isLoading = false;
        }
    }

    handleStatus(event) {
        this.status = event.detail.value;
        this.load();
    }

    handleIntegrity(event) {
        this.integrity = event.detail.value;
        this.load();
    }

    handleAgent(event) {
        this.agent = event.detail.value;
    }

    handleAgentKey(event) {
        if (event.key === 'Enter') {
            this.load();
        }
    }

    handleRefresh() {
        this.load();
    }
}
