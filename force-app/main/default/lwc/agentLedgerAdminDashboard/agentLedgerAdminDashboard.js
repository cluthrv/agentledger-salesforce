import { LightningElement } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';

import getAllSessionsFiltered
    from '@salesforce/apex/AgentAuditQueryService.getAllSessionsFiltered';

const COLUMNS = [
    { label: 'Session', fieldName: 'Name' },
    { label: 'Agent Name', fieldName: 'Agent_Name__c' },
    { label: 'Object', fieldName: 'Related_Object_API_Name__c' },
    { label: 'Use Case', fieldName: 'Use_Case__c' },
    { label: 'Status', fieldName: 'Status__c' },
    { label: 'Verification', fieldName: 'Verification_Status__c' },
    { label: 'Records', fieldName: 'Record_Count__c', type: 'number' },
    {
        type: 'button',
        typeAttributes: {
            label: 'View',
            name: 'view',
            variant: 'brand'
        }
    }
];

export default class AgentLedgerAdminDashboard extends NavigationMixin(LightningElement) {
    sessions = [];
    error;

    agentName = '';
    objectApiName = '';

    columns = COLUMNS;

    connectedCallback() {
        this.loadSessions();
    }

    get totalSessions() {
        return this.sessions.length;
    }

    get sealedSessions() {
        return this.sessions.filter(item => item.Status__c === 'Sealed').length;
    }

    get tamperedSessions() {
        return this.sessions.filter(item => item.Verification_Status__c === 'Tampered').length;
    }

    get activeSessions() {
        return this.sessions.filter(item => item.Status__c === 'Active').length;
    }

    handleAgentNameChange(event) {
        this.agentName = event.target.value;
    }

    handleObjectApiNameChange(event) {
        this.objectApiName = event.target.value;
    }

    async loadSessions() {
        this.error = undefined;

        const req = {
            agentName: this.agentName,
            objectApiName: this.objectApiName,
            limitCount: 100
        };

        try {
            this.sessions = await getAllSessionsFiltered({ req });
        } catch (error) {
            this.error = error.body ? error.body.message : 'Unable to load sessions.';
        }
    }

    resetFilters() {
        this.agentName = '';
        this.objectApiName = '';
        this.loadSessions();
    }

    handleRowAction(event) {
        const actionName = event.detail.action.name;
        const row = event.detail.row;

        if (actionName === 'view') {
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: {
                    recordId: row.Id,
                    objectApiName: 'Agent_Audit_Session__c',
                    actionName: 'view'
                }
            });
        }
    }
}
