global with sharing class RecordDecisionAction {

    global class Request {
        @InvocableVariable(required=true label='Session ID')
        global Id sessionId;

        @InvocableVariable(required=true label='Action Label')
        global String actionLabel;

        @InvocableVariable(label='Decision Category')
        global String decisionCategory;

        @InvocableVariable(label='Risk Level')
        global String riskLevel;

        @InvocableVariable(label='Target Record ID')
        global String targetRecordId;

        @InvocableVariable(label='Target Object API Name')
        global String targetObjectApiName;

        @InvocableVariable(label='Input Context')
        global String inputContext;

        @InvocableVariable(label='Output Result')
        global String outputResult;

        @InvocableVariable(label='Reasoning')
        global String reasoning;
    }

    global class Response {
        @InvocableVariable(label='Audit Record ID')
        global Id auditRecordId;

        @InvocableVariable(label='Sequence Number')
        global Integer sequenceNumber;

        @InvocableVariable(label='Record Hash')
        global String recordHash;

        @InvocableVariable(label='Success')
        global Boolean success;

        @InvocableVariable(label='Error Message')
        global String errorMessage;
    }

    @InvocableMethod(label='Record Agent Decision' description='Records an AgentLedger decision entry.')
    global static List<Response> invoke(List<Request> requests) {
        List<Response> responses = new List<Response>();

        for (Request input : requests) {
            AgentAuditModels.RecordActionRequest req = new AgentAuditModels.RecordActionRequest();
            req.sessionId = input.sessionId;
            req.actionType = 'Decision';
            req.actionLabel = input.actionLabel;
            req.decisionCategory = input.decisionCategory;
            req.riskLevel = input.riskLevel;
            req.targetRecordId = input.targetRecordId;
            req.targetObjectApiName = input.targetObjectApiName;
            req.inputContext = input.inputContext;
            req.outputResult = input.outputResult;
            req.reasoning = input.reasoning;

            AgentAuditModels.RecordActionResult result = AgentAuditRecorder.recordAction(req);

            Response res = new Response();
            res.auditRecordId = result.auditRecordId;
            res.sequenceNumber = result.sequenceNumber;
            res.recordHash = result.recordHash;
            res.success = result.success;
            res.errorMessage = result.errorMessage;
            responses.add(res);
        }

        return responses;
    }
}
