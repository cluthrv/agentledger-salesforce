import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';

import getSessionsByRecord
    from '@salesforce/apex/AgentAuditQueryService.getSessionsByRecord';

export default class AgentLedgerAuditTrail extends NavigationMixin(LightningElement) {

    @api recordId;

    sessions;
    error;

    @wire(getSessionsByRecord, {
        recordId: '$recordId',
        limitCount: 10
    })
    wiredSessions({ error, data }) {
        if (data) {
            this.sessions = data;
            this.error = undefined;
        } else if (error) {
            this.error = error.body ? error.body.message : 'Unknown error';
            this.sessions = undefined;
        }
    }

    get isEmpty() {
        return this.sessions && this.sessions.length === 0;
    }

    handleView(event) {
        const sessionId = event.target.dataset.id;

        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: sessionId,
                objectApiName: 'Agent_Audit_Session__c',
                actionName: 'view'
            }
        });
    }
}
