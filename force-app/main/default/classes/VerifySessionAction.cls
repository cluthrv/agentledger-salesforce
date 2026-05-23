global with sharing class VerifySessionAction {

    global class Request {
        @InvocableVariable(required=true label='Session ID')
        global Id sessionId;
    }

    global class Response {
        @InvocableVariable(label='Verified')
        global Boolean verified;

        @InvocableVariable(label='Verification Status')
        global String verificationStatus;

        @InvocableVariable(label='Merkle Root')
        global String merkleRoot;

        @InvocableVariable(label='Record Count')
        global Integer recordCount;

        @InvocableVariable(label='Error Message')
        global String errorMessage;
    }

    @InvocableMethod(label='Verify AgentLedger Session' description='Verifies hash chain and Merkle root for an AgentLedger session.')
    global static List<Response> invoke(List<Request> requests) {
        List<Response> responses = new List<Response>();

        for (Request input : requests) {
            AgentAuditModels.VerifySessionRequest req = new AgentAuditModels.VerifySessionRequest();
            req.sessionId = input.sessionId;

            AgentAuditModels.VerifySessionResult result = AgentAuditRecorder.verifySession(req);

            Response res = new Response();
            res.verified = result.verified;
            res.verificationStatus = result.verificationStatus;
            res.merkleRoot = result.merkleRoot;
            res.recordCount = result.recordCount;
            res.errorMessage = result.errorMessage;
            responses.add(res);
        }

        return responses;
    }
}
