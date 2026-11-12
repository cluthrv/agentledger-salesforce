trigger HardeningLogFailure on Agent_Audit_Record__c (before insert) {
    for (Agent_Audit_Record__c e : Trigger.new) {
        if (e.Reasoning__c != null && e.Reasoning__c.contains('FORCE_LOG_FAILURE')) {
            e.addError('Hardening: forced log failure');
        }
    }
}
