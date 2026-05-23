global with sharing class StartSessionAction {

    global class Request {
        @InvocableVariable(required=true label='Agent Name')
        global String agentName;

        @InvocableVariable(label='Agent Type')
        global String agentType;

        @InvocableVariable(label='Use Case Label')
        global String useCaseLabel;

        @InvocableVariable(label='Related Record ID')
        global String relatedRecordId;

        @InvocableVariable(label='Related Object API Name')
        global String relatedObjectApiName;

        @InvocableVariable(label='Platform')
        global String platform;

        @InvocableVariable(label='External Correlation ID')
        global String externalCorrelationId;

        @InvocableVariable(label='Session Notes')
        global String sessionNotes;
    }

    global class Response {
        @InvocableVariable(label='Session ID')
        global Id sessionId;

        @InvocableVariable(label='Session UUID')
        global String sessionUUID;

        @InvocableVariable(label='Success')
        global Boolean success;

        @InvocableVariable(label='Error Message')
        global String errorMessage;
    }

    @InvocableMethod(label='Start AgentLedger Session' description='Creates a new AgentLedger audit session.')
    global static List<Response> invoke(List<Request> requests) {
        List<Response> responses = new List<Response>();

        for (Request input : requests) {
            AgentAuditModels.StartSessionRequest req = new AgentAuditModels.StartSessionRequest();
            req.agentName = input.agentName;
            req.agentType = input.agentType;
            req.useCaseLabel = input.useCaseLabel;
            req.relatedRecordId = input.relatedRecordId;
            req.relatedObjectApiName = input.relatedObjectApiName;
            req.platform = input.platform;
            req.externalCorrelationId = input.externalCorrelationId;
            req.sessionNotes = input.sessionNotes;

            AgentAuditModels.StartSessionResult result = AgentAuditRecorder.startSession(req);

            Response res = new Response();
            res.sessionId = result.sessionId;
            res.sessionUUID = result.sessionUUID;
            res.success = result.success;
            res.errorMessage = result.errorMessage;
            responses.add(res);
        }

        return responses;
    }
}
