#!/usr/bin/env bash
set -e

BASE="force-app/main/default/objects"

mkdir -p "$BASE/Agent_Audit_Session__c/fields"
mkdir -p "$BASE/Agent_Audit_Record__c/fields"

cat > "$BASE/Agent_Audit_Session__c/Agent_Audit_Session__c.object-meta.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<CustomObject xmlns="http://soap.sforce.com/2006/04/metadata">
    <label>Agent Audit Session</label>
    <pluralLabel>Agent Audit Sessions</pluralLabel>
    <nameField>
        <label>Agent Audit Session Name</label>
        <type>AutoNumber</type>
        <displayFormat>AAS-{000000}</displayFormat>
    </nameField>
    <deploymentStatus>Deployed</deploymentStatus>
    <sharingModel>ReadWrite</sharingModel>
    <enableActivities>false</enableActivities>
    <enableHistory>true</enableHistory>
    <enableReports>true</enableReports>
    <enableSearch>true</enableSearch>
</CustomObject>
XML

cat > "$BASE/Agent_Audit_Record__c/Agent_Audit_Record__c.object-meta.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<CustomObject xmlns="http://soap.sforce.com/2006/04/metadata">
    <label>Agent Audit Record</label>
    <pluralLabel>Agent Audit Records</pluralLabel>
    <nameField>
        <label>Agent Audit Record Name</label>
        <type>AutoNumber</type>
        <displayFormat>AAR-{000000}</displayFormat>
    </nameField>
    <deploymentStatus>Deployed</deploymentStatus>
    <sharingModel>ControlledByParent</sharingModel>
    <enableActivities>false</enableActivities>
    <enableHistory>false</enableHistory>
    <enableReports>true</enableReports>
    <enableSearch>true</enableSearch>
</CustomObject>
XML

text_field () {
cat > "$1/fields/$2.field-meta.xml" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>$2</fullName>
    <label>$3</label>
    <length>$4</length>
    <required>false</required>
    <type>Text</type>
</CustomField>
XML
}

long_text_field () {
cat > "$1/fields/$2.field-meta.xml" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>$2</fullName>
    <label>$3</label>
    <length>$4</length>
    <type>LongTextArea</type>
    <visibleLines>5</visibleLines>
</CustomField>
XML
}

datetime_field () {
cat > "$1/fields/$2.field-meta.xml" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>$2</fullName>
    <label>$3</label>
    <required>false</required>
    <type>DateTime</type>
</CustomField>
XML
}

number_field () {
cat > "$1/fields/$2.field-meta.xml" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>$2</fullName>
    <label>$3</label>
    <precision>$4</precision>
    <scale>0</scale>
    <required>false</required>
    <type>Number</type>
</CustomField>
XML
}

SESSION="$BASE/Agent_Audit_Session__c"
RECORD="$BASE/Agent_Audit_Record__c"

text_field "$SESSION" "Agent_Name__c" "Agent Name" 255
text_field "$SESSION" "Agent_Type__c" "Agent Type" 100
text_field "$SESSION" "Use_Case__c" "Use Case Label" 255
text_field "$SESSION" "Merkle_Root__c" "Merkle Root" 64
text_field "$SESSION" "Related_Record_Id__c" "Related Record ID" 18
text_field "$SESSION" "Related_Object_API_Name__c" "Related Object API Name" 100
text_field "$SESSION" "Initiator__c" "Initiator" 255
text_field "$SESSION" "Platform__c" "Platform" 100
long_text_field "$SESSION" "Error_Message__c" "Error Message" 2000
long_text_field "$SESSION" "Seal_Error__c" "Seal Error" 2000
long_text_field "$SESSION" "Session_Notes__c" "Session Notes" 2000
datetime_field "$SESSION" "Start_Time__c" "Start Time"
datetime_field "$SESSION" "End_Time__c" "End Time"
number_field "$SESSION" "Record_Count__c" "Record Count" 10

cat > "$SESSION/fields/Session_Id__c.field-meta.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Session_Id__c</fullName>
    <externalId>true</externalId>
    <label>Session ID</label>
    <length>80</length>
    <required>false</required>
    <type>Text</type>
    <unique>false</unique>
</CustomField>
XML

cat > "$SESSION/fields/External_Correlation_Id__c.field-meta.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>External_Correlation_Id__c</fullName>
    <externalId>true</externalId>
    <label>External Correlation ID</label>
    <length>255</length>
    <required>false</required>
    <type>Text</type>
    <unique>false</unique>
</CustomField>
XML

cat > "$SESSION/fields/Status__c.field-meta.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Status__c</fullName>
    <label>Status</label>
    <required>false</required>
    <trackHistory>true</trackHistory>
    <type>Picklist</type>
    <valueSet>
        <restricted>true</restricted>
        <valueSetDefinition>
            <sorted>false</sorted>
            <value><fullName>Active</fullName><default>true</default><label>Active</label></value>
            <value><fullName>Sealed</fullName><default>false</default><label>Sealed</label></value>
            <value><fullName>Failed</fullName><default>false</default><label>Failed</label></value>
            <value><fullName>Cancelled</fullName><default>false</default><label>Cancelled</label></value>
        </valueSetDefinition>
    </valueSet>
</CustomField>
XML

cat > "$SESSION/fields/Verification_Status__c.field-meta.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Verification_Status__c</fullName>
    <label>Verification Status</label>
    <required>false</required>
    <trackHistory>true</trackHistory>
    <type>Picklist</type>
    <valueSet>
        <restricted>true</restricted>
        <valueSetDefinition>
            <sorted>false</sorted>
            <value><fullName>Unverified</fullName><default>true</default><label>Unverified</label></value>
            <value><fullName>Verified</fullName><default>false</default><label>Verified</label></value>
            <value><fullName>Tampered</fullName><default>false</default><label>Tampered</label></value>
            <value><fullName>Error</fullName><default>false</default><label>Error</label></value>
        </valueSetDefinition>
    </valueSet>
</CustomField>
XML

cat > "$RECORD/fields/Audit_Session__c.field-meta.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Audit_Session__c</fullName>
    <label>Audit Session</label>
    <referenceTo>Agent_Audit_Session__c</referenceTo>
    <relationshipLabel>Audit Records</relationshipLabel>
    <relationshipName>Audit_Records</relationshipName>
    <type>MasterDetail</type>
    <writeRequiresMasterRead>false</writeRequiresMasterRead>
</CustomField>
XML

number_field "$RECORD" "Sequence_Number__c" "Sequence Number" 10
text_field "$RECORD" "Action_Label__c" "Action Label" 255
text_field "$RECORD" "Target_Record_Id__c" "Target Record ID" 18
text_field "$RECORD" "Target_Object_API_Name__c" "Target Object API Name" 100
long_text_field "$RECORD" "Input_Context__c" "Input Context" 32768
long_text_field "$RECORD" "Output_Result__c" "Output Result" 32768
long_text_field "$RECORD" "Reasoning__c" "Reasoning" 32768
datetime_field "$RECORD" "Action_Timestamp__c" "Action Timestamp"
text_field "$RECORD" "Previous_Hash__c" "Previous Hash" 64
text_field "$RECORD" "Record_Hash__c" "Record Hash" 64

cat > "$RECORD/fields/Action_Type__c.field-meta.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Action_Type__c</fullName>
    <label>Action Type</label>
    <required>false</required>
    <type>Picklist</type>
    <valueSet>
        <restricted>true</restricted>
        <valueSetDefinition>
            <sorted>false</sorted>
            <value><fullName>Decision</fullName><default>true</default><label>Decision</label></value>
            <value><fullName>Action</fullName><default>false</default><label>Action</label></value>
            <value><fullName>Observation</fullName><default>false</default><label>Observation</label></value>
            <value><fullName>Error</fullName><default>false</default><label>Error</label></value>
        </valueSetDefinition>
    </valueSet>
</CustomField>
XML

cat > "$RECORD/fields/Decision_Category__c.field-meta.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Decision_Category__c</fullName>
    <label>Decision Category</label>
    <required>false</required>
    <type>Picklist</type>
    <valueSet>
        <restricted>true</restricted>
        <valueSetDefinition>
            <sorted>false</sorted>
            <value><fullName>Approval</fullName><default>false</default><label>Approval</label></value>
            <value><fullName>Escalation</fullName><default>false</default><label>Escalation</label></value>
            <value><fullName>Pricing</fullName><default>false</default><label>Pricing</label></value>
            <value><fullName>Recommendation</fullName><default>false</default><label>Recommendation</label></value>
            <value><fullName>Other</fullName><default>true</default><label>Other</label></value>
        </valueSetDefinition>
    </valueSet>
</CustomField>
XML

cat > "$RECORD/fields/Risk_Level__c.field-meta.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Risk_Level__c</fullName>
    <label>Risk Level</label>
    <required>false</required>
    <type>Picklist</type>
    <valueSet>
        <restricted>true</restricted>
        <valueSetDefinition>
            <sorted>false</sorted>
            <value><fullName>Low</fullName><default>true</default><label>Low</label></value>
            <value><fullName>Medium</fullName><default>false</default><label>Medium</label></value>
            <value><fullName>High</fullName><default>false</default><label>High</label></value>
        </valueSetDefinition>
    </valueSet>
</CustomField>
XML

echo "Metadata created."