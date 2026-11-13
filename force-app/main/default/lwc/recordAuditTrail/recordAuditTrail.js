import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getTimeline from '@salesforce/apex/AgentLedgerTimelineController.getTimeline';
import verifyRun from '@salesforce/apex/AgentLedgerTimelineController.verifyRun';
import exportRun from '@salesforce/apex/AgentLedgerEvidence.exportRun';
import reconcileRun from '@salesforce/apex/AgentLedgerReconciliation.reconcileRun';

const PAGE_SIZE = 10;

const TYPE_ICONS = {
    Recommendation: 'utility:like',
    Decision: 'utility:approval',
    Human_Response: 'utility:user',
    Query: 'utility:search',
    Validation: 'utility:check',
    Calculation: 'utility:formula',
    Data_Change: 'utility:edit',
    Update: 'utility:edit',
    Create: 'utility:add',
    Delete: 'utility:delete',
    Escalation: 'utility:priority',
    Tool_Call: 'utility:settings',
    Error: 'utility:warning'
};

const STATUS_VARIANT = { Active: 'slds-theme_info', Closed: '', Incomplete: 'slds-theme_warning' };

/**
 * AgentLedger activity timeline: what agents did on this record, in plain
 * language, newest run first. Verification appears only for runs recorded in a
 * tamper-evident mode.
 */
export default class RecordAuditTrail extends LightningElement {
    @api recordId;

    runs = [];
    hasMore = false;
    isLoading = true;
    loadError;
    expanded = new Set();
    verifying = new Set();
    exporting = new Set();
    reconciling = new Set();
    reconciled = {};
    rawRuns = [];

    connectedCallback() {
        this.load();
    }

    get isEmpty() {
        return !this.isLoading && !this.loadError && this.runs.length === 0;
    }

    async load(append = false) {
        this.isLoading = true;
        this.loadError = undefined;
        try {
            const before = append && this.rawRuns.length
                ? this.rawRuns[this.rawRuns.length - 1].startTime
                : null;
            const result = await getTimeline({ recordId: this.recordId, pageSize: PAGE_SIZE, startedBefore: before });
            this.rawRuns = append ? [...this.rawRuns, ...result.runs] : result.runs;
            this.hasMore = result.hasMore;
            this.buildView();
        } catch (error) {
            this.loadError = reduceError(error);
        } finally {
            this.isLoading = false;
        }
    }

    handleRefresh() {
        this.load(false);
    }

    handleShowOlder() {
        this.load(true);
    }

    handleToggle(event) {
        const id = event.currentTarget.dataset.entryId;
        if (this.expanded.has(id)) {
            this.expanded.delete(id);
        } else {
            this.expanded.add(id);
        }
        this.buildView();
    }

    async handleVerify(event) {
        const runId = event.currentTarget.dataset.runId;
        this.verifying.add(runId);
        this.buildView();
        try {
            const updated = await verifyRun({ runId });
            this.rawRuns = this.rawRuns.map((r) => (r.runId === runId
                ? { ...r, integrity: updated.integrity, lastVerifiedAt: updated.lastVerifiedAt, status: updated.status }
                : r));
            const ok = updated.integrity === 'Verified';
            this.dispatchEvent(new ShowToastEvent({
                title: ok ? 'Verified' : 'Tampered',
                message: ok
                    ? 'Every step of ' + updated.name + ' matches what was recorded.'
                    : 'A step of ' + updated.name + ' no longer matches what was recorded.',
                variant: ok ? 'success' : 'error'
            }));
        } catch (error) {
            this.dispatchEvent(new ShowToastEvent({ title: 'Could not verify', message: reduceError(error), variant: 'error' }));
        } finally {
            this.verifying.delete(runId);
            this.buildView();
        }
    }

    // Downloads the run as JSON that the open-source verifiers check outside Salesforce.
    async handleExport(event) {
        const runId = event.currentTarget.dataset.runId;
        this.exporting.add(runId);
        this.buildView();
        try {
            const result = await exportRun({ runId });
            const link = document.createElement('a');
            link.href = 'data:application/json;charset=utf-8,' + encodeURIComponent(result.json);
            link.download = result.fileName;
            link.click();
            this.dispatchEvent(new ShowToastEvent({
                title: 'Exported',
                message: result.hiddenEntries > 0
                    ? result.hiddenEntries + ' step(s) include fields you do not have access to; their values were left out, so those steps will not verify.'
                    : 'Verify it anywhere with: npx @vluthra/agent-ledger verify ' + result.fileName,
                variant: result.hiddenEntries > 0 ? 'warning' : 'success'
            }));
        } catch (error) {
            this.dispatchEvent(new ShowToastEvent({ title: 'Could not export', message: reduceError(error), variant: 'error' }));
        } finally {
            this.exporting.delete(runId);
            this.buildView();
        }
    }

    // Compares the run with Salesforce's own Field History.
    async handleReconcile(event) {
        const runId = event.currentTarget.dataset.runId;
        this.reconciling.add(runId);
        this.buildView();
        try {
            const result = await reconcileRun({ runId });
            this.reconciled = { ...this.reconciled, [runId]: result };
        } catch (error) {
            this.dispatchEvent(new ShowToastEvent({ title: 'Could not check history', message: reduceError(error), variant: 'error' }));
        } finally {
            this.reconciling.delete(runId);
            this.buildView();
        }
    }

    reconcileView(runId) {
        const r = this.reconciled[runId];
        if (!r) {
            return null;
        }
        const hasMissing = r.missing && r.missing.length > 0;
        return {
            summary: r.summary,
            hasMissing,
            missing: (r.missing || []).map((m, i) => ({ ...m, key: runId + '-' + i })),
            boxClass: 'reconcile slds-box slds-box_x-small slds-m-bottom_small ' + (hasMissing ? 'reconcile-missing' : 'reconcile-ok')
        };
    }

    // Build the view model the template renders.
    buildView() {
        this.runs = this.rawRuns.map((r) => {
            const integrity = r.integrity === 'Verified' || r.integrity === 'Tampered' ? r.integrity : 'Not checked';
            return {
                ...r,
                statusClass: 'slds-badge ' + (STATUS_VARIANT[r.status] || ''),
                showIntegrity: r.tamperEvident,
                integrityLabel: integrity,
                integrityClass: 'slds-badge ' + (integrity === 'Verified' ? 'slds-theme_success'
                    : integrity === 'Tampered' ? 'slds-theme_error' : ''),
                hasVerifiedTime: r.tamperEvident && !!r.lastVerifiedAt,
                isVerifying: this.verifying.has(r.runId),
                showVerify: r.tamperEvident && r.status !== 'Active',
                showExport: r.tamperEvident,
                isExporting: this.exporting.has(r.runId),
                isReconciling: this.reconciling.has(r.runId),
                reconcile: this.reconcileView(r.runId),
                stepsLabel: r.entryCount === 1 ? '1 step' : r.entryCount + ' steps',
                otherRecord: !r.aboutThisRecord,
                hasActedUnder: !!(r.agentVersion || r.policyReference),
                snapshotUrl: r.instructionsSnapshotId
                    ? '/lightning/r/Agent_Instructions_Snapshot__c/' + r.instructionsSnapshotId + '/view' : null,
                runUrl: '/lightning/r/Agent_Audit_Session__c/' + r.runId + '/view',
                entries: (r.entries || []).map((e) => ({
                    ...e,
                    icon: TYPE_ICONS[e.type] || 'utility:record',
                    summaryText: e.summary || e.typeLabel,
                    captureClass: 'capture ' + (e.detected ? 'capture-detected' : e.capturedByCode ? 'capture-code' : 'capture-agent'),
                    isExpanded: this.expanded.has(e.entryId),
                    toggleLabel: this.expanded.has(e.entryId) ? 'Hide details' : 'Details',
                    hasFieldChanges: e.fieldChanges && e.fieldChanges.length > 0,
                    fieldChangeRows: (e.fieldChanges || []).map((c, i) => ({
                        key: e.entryId + '-' + i,
                        label: c.label || c.field,
                        before: c.before == null ? '(blank)' : c.before,
                        after: c.after == null ? '(blank)' : c.after
                    })),
                    hasHidden: e.hiddenFieldChanges > 0,
                    hiddenLabel: e.hiddenFieldChanges === 1
                        ? '1 more field changed that you do not have access to.'
                        : e.hiddenFieldChanges + ' more fields changed that you do not have access to.',
                    elsewhere: !!e.targetRecordId && !e.targetsThisRecord,
                    elsewhereUrl: e.targetRecordId ? '/lightning/r/' + e.targetRecordId + '/view' : null
                }))
            };
        });
    }
}

function reduceError(error) {
    if (!error) {
        return 'Unknown error';
    }
    if (error.body && error.body.message) {
        return error.body.message;
    }
    return error.message || JSON.stringify(error);
}
