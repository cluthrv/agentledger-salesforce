/**
 * AgentLedgerSettingsCallback
 *
 * Receives the result of saving AgentLedger settings through the Metadata API.
 * The Setup page reloads the settings itself; a failure is logged here.
 */
public with sharing class AgentLedgerSettingsCallback implements Metadata.DeployCallback {
    public void handleResult(Metadata.DeployResult result, Metadata.DeployCallbackContext context) {
        if (result.status != Metadata.DeployStatus.Succeeded) {
            System.debug(LoggingLevel.ERROR, 'AgentLedger settings were not saved: ' + result.errorMessage);
        }
    }
}
