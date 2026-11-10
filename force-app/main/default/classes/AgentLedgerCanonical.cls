/**
 * AgentLedgerCanonical
 *
 * Canonical JSON (RFC 8785) for the values AgentLedger hashes, byte for byte
 * the same as canonicalJson in the open-source library (@vluthra/agent-ledger,
 * vluthra-agent-ledger), so a run exported from Salesforce verifies with those
 * verifiers.
 *
 * Supported values: null, Boolean, Integer, Long, String, List<Object> and
 * Map<String, Object>. Object keys are sorted; strings are escaped as
 * JavaScript's JSON.stringify escapes them (", \, and control characters; all
 * other characters, including non-ASCII, are written as is). Decimals and
 * other types are rejected rather than formatted in a way the other
 * implementations might not reproduce.
 */
public with sharing class AgentLedgerCanonical {

    private static List<String> controlChars;
    private static String specialChars;

    public static String serialize(Object value) {
        if (value == null) {
            return 'null';
        }
        if (value instanceof String) {
            return quote((String) value);
        }
        if (value instanceof Boolean) {
            return ((Boolean) value) ? 'true' : 'false';
        }
        if (value instanceof Integer || value instanceof Long) {
            return String.valueOf(value);
        }
        if (value instanceof Map<String, Object>) {
            Map<String, Object> m = (Map<String, Object>) value;
            List<String> keys = new List<String>(m.keySet());
            keys.sort();
            List<String> parts = new List<String>();
            for (String k : keys) {
                parts.add(quote(k) + ':' + serialize(m.get(k)));
            }
            return '{' + String.join(parts, ',') + '}';
        }
        if (value instanceof List<Object>) {
            List<String> parts = new List<String>();
            for (Object item : (List<Object>) value) {
                parts.add(serialize(item));
            }
            return '[' + String.join(parts, ',') + ']';
        }
        throw new CanonicalException('AgentLedgerCanonical: unsupported value type for ' + String.valueOf(value));
    }

    /** A JSON string literal, escaped as JSON.stringify escapes it. */
    public static String quote(String s) {
        init();
        if (!s.containsAny(specialChars)) {
            return '"' + s + '"';
        }
        String out = s.replace('\\', '\\\\').replace('"', '\\"');
        for (Integer c = 0; c < 32; c++) {
            String ch = controlChars[c];
            if (out.contains(ch)) {
                out = out.replace(ch, escapeControl(c));
            }
        }
        return '"' + out + '"';
    }

    private static String escapeControl(Integer c) {
        switch on c {
            when 8 { return '\\b'; }
            when 9 { return '\\t'; }
            when 10 { return '\\n'; }
            when 12 { return '\\f'; }
            when 13 { return '\\r'; }
            when else {
                String hex = EncodingUtil.convertToHex(Blob.valueOf(String.fromCharArray(new List<Integer>{ c })));
                return '\\u00' + hex;
            }
        }
    }

    private static void init() {
        if (controlChars != null) {
            return;
        }
        controlChars = new List<String>();
        for (Integer c = 0; c < 32; c++) {
            controlChars.add(String.fromCharArray(new List<Integer>{ c }));
        }
        specialChars = '"\\' + String.join(controlChars, '');
    }

    public class CanonicalException extends Exception {}
}
