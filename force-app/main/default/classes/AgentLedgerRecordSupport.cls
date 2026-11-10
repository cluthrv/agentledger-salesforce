/**
 * AgentLedgerRecordSupport
 *
 * Shared by the recorded actions (Get, Update and Create Record
 * (AgentLedger)): field lookup and type conversion, reading and writing
 * business records with the running user's permissions, the privacy settings,
 * and the field-change list stored on an entry.
 */
public with sharing class AgentLedgerRecordSupport {

    public static final String NOT_STORED = '(not stored)';
    private static final Integer MAX_DEFAULT_FIELDS = 100;

    public class RecordException extends Exception {}

    /** One changed or written field, as stored in Field_Changes__c. */
    public class FieldChange {
        public String field;
        public String label;
        public String before;
        public String after;
    }

    /** Field values from the JSON object the agent passes, e.g. {"Status":"Escalated"}. */
    public static Map<String, Object> parseFieldValues(String json) {
        if (String.isBlank(json)) {
            throw new RecordException('Field Values is required, as a JSON object such as {"Status": "Escalated"}.');
        }
        Object parsed;
        try {
            parsed = System.JSON.deserializeUntyped(json);
        } catch (Exception e) {
            throw new RecordException('Field Values is not valid JSON: ' + e.getMessage());
        }
        if (!(parsed instanceof Map<String, Object>)) {
            throw new RecordException('Field Values must be a JSON object such as {"Status": "Escalated"}.');
        }
        return (Map<String, Object>) parsed;
    }

    /** The describe of a field the running user may write, or an exception saying why not. */
    public static Schema.DescribeFieldResult writableField(Schema.DescribeSObjectResult objectDescribe, String fieldName, Boolean forCreate) {
        Schema.SObjectField f = objectDescribe.fields.getMap().get(fieldName.trim().toLowerCase());
        if (f == null) {
            throw new RecordException(objectDescribe.getName() + ' has no field named ' + fieldName + '.');
        }
        Schema.DescribeFieldResult d = f.getDescribe();
        if (forCreate ? !d.isCreateable() : !d.isUpdateable()) {
            throw new RecordException('You cannot ' + (forCreate ? 'set' : 'change') + ' ' + objectDescribe.getName() + '.' + d.getName() + '.');
        }
        return d;
    }

    /** Convert a JSON value to the field's Apex type. */
    public static Object coerce(Schema.DescribeFieldResult d, Object value) {
        if (value == null || (value instanceof String && String.isBlank((String) value))) {
            return null;
        }
        String s = String.valueOf(value).trim();
        try {
            switch on d.getType() {
                when BOOLEAN {
                    if (value instanceof Boolean) {
                        return value;
                    }
                    if (s.equalsIgnoreCase('true') || s.equalsIgnoreCase('false')) {
                        return Boolean.valueOf(s);
                    }
                    throw new RecordException('not true or false');
                }
                when INTEGER {
                    return Integer.valueOf(s);
                }
                when LONG {
                    return Long.valueOf(s);
                }
                when DOUBLE, CURRENCY, PERCENT {
                    return Decimal.valueOf(s);
                }
                when DATE {
                    return Date.valueOf(s.left(10));
                }
                when DATETIME {
                    return (DateTime) System.JSON.deserialize('"' + s + '"', DateTime.class);
                }
                when REFERENCE, ID {
                    return Id.valueOf(s);
                }
                when else {
                    return s;
                }
            }
        } catch (Exception e) {
            throw new RecordException('"' + s + '" is not a valid value for ' + d.getName() + ' (' + String.valueOf(d.getType()) + ').');
        }
    }

    /** A field value as text for the log. */
    public static String format(Object value) {
        if (value == null) {
            return null;
        }
        if (value instanceof DateTime) {
            return ((DateTime) value).formatGmt('yyyy-MM-dd\'T\'HH:mm:ss.SSS\'Z\'');
        }
        if (value instanceof Date) {
            return String.valueOf((Date) value);
        }
        if (value instanceof Decimal) {
            return ((Decimal) value).stripTrailingZeros().toPlainString();
        }
        return String.valueOf(value);
    }

    /** The object's name field (Name, CaseNumber, Subject...), or null. */
    public static String nameField(Schema.DescribeSObjectResult objectDescribe) {
        for (Schema.SObjectField f : objectDescribe.fields.getMap().values()) {
            Schema.DescribeFieldResult d = f.getDescribe();
            if (d.isNameField()) {
                return d.getName();
            }
        }
        return null;
    }

    /** Fields to read when the agent names none: accessible fields, up to a limit. */
    public static List<String> defaultReadFields(Schema.DescribeSObjectResult objectDescribe) {
        List<String> names = new List<String>();
        for (Schema.SObjectField f : objectDescribe.fields.getMap().values()) {
            Schema.DescribeFieldResult d = f.getDescribe();
            if (d.isAccessible() && d.getType() != Schema.DisplayType.ADDRESS && d.getType() != Schema.DisplayType.LOCATION
                && d.getType() != Schema.DisplayType.BASE64) {
                names.add(d.getName());
                if (names.size() >= MAX_DEFAULT_FIELDS) {
                    break;
                }
            }
        }
        return names;
    }

    /** Read fields of one record with the running user's permissions. */
    public static SObject readRecord(Id recordId, Set<String> fields) {
        Schema.DescribeSObjectResult d = recordId.getSObjectType().getDescribe();
        Set<String> selected = new Set<String>{ 'Id' };
        selected.addAll(fields);
        String soql = 'SELECT ' + String.join(new List<String>(selected), ', ') + ' FROM ' + d.getName() + ' WHERE Id = :recordId';
        List<SObject> rows = Database.queryWithBinds(soql, new Map<String, Object>{ 'recordId' => recordId }, AccessLevel.USER_MODE);
        if (rows.isEmpty()) {
            throw new RecordException('Record ' + recordId + ' was not found, or you do not have access to it.');
        }
        return rows[0];
    }

    /** The record's display name, e.g. "Case 00001027". */
    public static String displayName(SObject record, Schema.DescribeSObjectResult d) {
        String nf = nameField(d);
        Object name = null;
        if (nf != null) {
            try {
                name = record.get(nf);
            } catch (SObjectException e) {
                name = null;
            }
        }
        return d.getLabel() + ' ' + (name != null ? String.valueOf(name) : String.valueOf(record.Id));
    }

    /** Whether a field's values may be stored in the log under the privacy settings. */
    public static Boolean mayStoreValue(AgentLedgerSettings.Resolved settings, String objectName, String fieldName) {
        if (!settings.storeFieldValues) {
            return false;
        }
        String key = (objectName + '.' + fieldName).toLowerCase();
        for (String never : settings.neverStoreFields) {
            if (never.toLowerCase() == key) {
                return false;
            }
        }
        return true;
    }

    public static FieldChange change(AgentLedgerSettings.Resolved settings, String objectName,
                                     Schema.DescribeFieldResult d, Object before, Object after) {
        FieldChange c = new FieldChange();
        c.field = d.getName();
        c.label = d.getLabel();
        Boolean store = mayStoreValue(settings, objectName, d.getName());
        c.before = store ? format(before) : NOT_STORED;
        c.after = store ? format(after) : NOT_STORED;
        return c;
    }

    /** Field values for the log, with the privacy settings applied. */
    public static Map<String, Object> loggableValues(AgentLedgerSettings.Resolved settings, String objectName,
                                                     SObject record, List<String> fields) {
        Map<String, Object> out = new Map<String, Object>();
        for (String f : fields) {
            Object v;
            try {
                v = record.get(f);
            } catch (SObjectException e) {
                continue;
            }
            out.put(f, mayStoreValue(settings, objectName, f) ? format(v) : NOT_STORED);
        }
        return out;
    }

    /** "Status: New → Escalated; Priority: High" style summary of changes. */
    public static String describeChanges(List<FieldChange> changes) {
        List<String> parts = new List<String>();
        for (FieldChange c : changes) {
            parts.add(c.label + ': ' + (c.before == null ? '(blank)' : c.before) + ' → ' + (c.after == null ? '(blank)' : c.after));
        }
        return String.join(parts, '; ');
    }

    /** Text cut to a field length. */
    public static String fit(String s, Integer length) {
        return s == null || s.length() <= length ? s : s.left(length - 1) + '…';
    }
}
