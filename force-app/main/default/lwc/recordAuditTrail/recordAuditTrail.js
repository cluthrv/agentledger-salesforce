import { LightningElement, api, wire, track } from 'lwc';
import getSessionsForRecord from '@salesforce/apex/RecordAuditTrailController.getSessionsForRecord';
import verifySessionFromRecord from '@salesforce/apex/RecordAuditTrailController.verifySessionFromRecord';

const TYPE_BADGE_MAP = {
    'Query': 'type-badge type-query',
    'Validation': 'type-badge type-validation',
    'Decision': 'type-badge type-decision',
    'Calculation': 'type-badge type-calculation',
    'Create': 'type-badge type-create',
    'Update': 'type-badge type-update',
    'Tool_Call': 'type-badge type-query',
    'Escalation': 'type-badge type-decision',
    'Delete': 'type-badge type-decision'
};

// The latest verification result and when it ran. A result is never shown
// without its time, so an old result cannot pass for a current one.
function integrityView(integrity, lastVerifiedAt) {
    const checked = integrity === 'Verified' || integrity === 'Tampered';
    return {
        hasIntegrity: checked,
        integrityLabel: checked
            ? integrity + ' ' + (lastVerifiedAt ? new Date(lastVerifiedAt).toLocaleString() : '')
            : '',
        integrityClass: integrity === 'Verified' ? 'status-pill status-verified' : 'status-pill status-tampered'
    };
}

export default class RecordAuditTrail extends LightningElement {
    @api recordId;
    @track sessions = [];
    isLoading = true;

    @wire(getSessionsForRecord, { recordId: '$recordId' })
    wiredSessions({ error, data }) {
        this.isLoading = false;
        if (data) {
            this.sessions = data.map(session => ({
                ...session,
                ...integrityView(session.integrity, session.lastVerifiedAt),
                isSealed: session.closed,
                status: session.lifecycle,
                statusClass: session.closed ? 'status-pill status-sealed' : 'status-pill status-active',
                startTimeFormatted: session.startTime ? new Date(session.startTime).toLocaleString() : '',
                verifyResult: null,
                verifyClass: '',
                verifyIcon: '',
                verifyVariant: '',
                verifyMessage: '',
                records: session.records.map(rec => ({
                    ...rec,
                    shortHash: rec.recordHash ? rec.recordHash.substring(0, 16) + '...' : '',
                    prevIndex: rec.sequenceNumber - 1,
                    typeBadge: TYPE_BADGE_MAP[rec.actionType] || 'type-badge type-query'
                }))
            }));
        } else if (error) {
            console.error('Error loading audit trail:', error);
            this.sessions = [];
        }
    }

    get hasNoSessions() {
        return this.sessions.length === 0;
    }

    get hasSessions() {
        return this.sessions.length > 0;
    }

    async handleVerify(event) {
        const sessionId = event.target.dataset.sessionId;
        try {
            const result = await verifySessionFromRecord({ sessionId });
            // The Apex verify updates the session Status to Verified or Tampered.
            // Reflect that new status in the UI immediately, and keep the
            // Verify button available so a fixed session can be re-verified.
            this.sessions = this.sessions.map(s => {
                if (s.sessionId === sessionId) {
                    return {
                        ...s,
                        ...integrityView(result.valid ? 'Verified' : 'Tampered', new Date().toISOString()),
                        verifyResult: result,
                        verifyClass: result.valid ? 'verify-result verify-pass' : 'verify-result verify-fail',
                        verifyIcon: result.valid ? 'utility:success' : 'utility:error',
                        verifyVariant: result.valid ? 'success' : 'error',
                        verifyMessage: result.valid
                            ? 'Verified: All ' + s.recordCount + ' records have valid hashes and chain linkage'
                            : 'FAILED: ' + result.message
                    };
                }
                return s;
            });
        } catch (error) {
            console.error('Verification error:', error);
        }
    }
}