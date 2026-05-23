global with sharing class SealSessionAction {

    global class Request {
        @InvocableVariable(required=true label='Session ID')
        global Id sessionId;
    }

    global class Response {
        @InvocableVariable(label='Success')
        global Boolean success;

        @InvocableVariable(label='Session ID')
        global Id sessionId;

        @InvocableVariable(label='Merkle Root')
        global String merkleRoot;

        @InvocableVariable(label='Record Count')
        global Integer recordCount;

        @InvocableVariable(label='Verification Status')
        global String verificationStatus;

        @InvocableVariable(label='Error Message')
        global String errorMessage;
    }

    @InvocableMethod(label='Seal AgentLedger Session' description='Seals an AgentLedger session and computes the Merkle root.')
    global static List<Response> invoke(List<Request> requests) {
        List<Response> responses = new List<Response>();

        for (Request input : requests) {
            AgentAuditModels.SealSessionRequest req = new AgentAuditModels.SealSessionRequest();
            req.sessionId = input.sessionId;

            AgentAuditModels.SealSessionResult result = AgentAuditRecorder.sealSession(req);

            Response res = new Response();
            res.success = result.success;
            res.sessionId = result.sessionId;
            res.merkleRoot = result.merkleRoot;
            res.recordCount = result.recordCount;
            res.verificationStatus = result.verificationStatus;
            res.errorMessage = result.errorMessage;
            responses.add(res);
        }

        return responses;
    }
}
