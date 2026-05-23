import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';

import getSessionSummary
    from '@salesforce/apex/AgentAuditQueryService.getSessionSummary';
import getRecordsBySession
    from '@salesforce/apex/AgentAuditQueryService.getRecordsBySession';
import verifySessionForLwc
    from '@salesforce/apex/AgentAuditQueryService.verifySessionForLwc';

export default class AgentLedgerSessionViewer extends LightningElement {
    @api recordId;

    session;
    records;
    error;
    verifyMessage;
    isVerifying = false;

    wiredSessionResult;
    wiredRecordsResult;

    @wire(getSessionSummary, { sessionId: '$recordId' })
    wiredSession(result) {
        this.wiredSessionResult = result;
        if (result.data) {
            this.session = result.data;
            this.error = undefined;
        } else if (result.error) {
            this.error = result.error.body ? result.error.body.message : 'Unable to load session.';
            this.session = undefined;
        }
    }

    @wire(getRecordsBySession, { sessionId: '$recordId' })
    wiredRecords(result) {
        this.wiredRecordsResult = result;
        if (result.data) {
            this.records = result.data;
            this.error = undefined;
        } else if (result.error) {
            this.error = result.error.body ? result.error.body.message : 'Unable to load records.';
            this.records = undefined;
        }
    }

    async handleVerify() {
        this.isVerifying = true;
        this.verifyMessage = undefined;

        try {
            const result = await verifySessionForLwc({ sessionId: this.recordId });

            if (result.verified) {
                this.verifyMessage = 'Audit trail verified successfully.';
            } else {
                this.verifyMessage = 'Verification failed: ' + result.verificationStatus;
            }

            await refreshApex(this.wiredSessionResult);
            await refreshApex(this.wiredRecordsResult);
        } catch (error) {
            this.verifyMessage = error.body ? error.body.message : 'Verification failed.';
        } finally {
            this.isVerifying = false;
        }
    }
}
