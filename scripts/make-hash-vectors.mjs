// Generates force-app/main/default/classes/AgentLedgerHashVectorsTest.cls from the
// published open-source library, so the Apex v2 hashing is tested against the
// exact bytes the npm and PyPI verifiers produce.
//
//   npm install --prefix scripts/.vectors @vluthra/agent-ledger@0.2.0
//   node scripts/make-hash-vectors.mjs
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const require = createRequire(path.join(here, '.vectors', 'package.json'));
const lib = require('@vluthra/agent-ledger');
const { hashActionRecordV2, computeMerkleRootV2, generateMerkleProofV2, canonicalJson } = lib;
const libVersion = require('@vluthra/agent-ledger/package.json').version;

const SESSION = '13a97669-8f6a-4c36-9391-ac982140e2c3';

// Each vector lists the Salesforce field values; toRecord maps them the way
// HashChainService.entryContentV2 does.
const vectors = [
  {
    name: 'first entry, plain values',
    fields: {
      Entry_Id__c: '8c0d4c8a-1f2e-4b7a-9f00-000000000001',
      Sequence_Number__c: 0,
      Timestamp_Text__c: '2026-11-09T14:03:27.481Z',
      Agent_Id__c: 'case-escalation-agent',
      Action_Type__c: 'Query',
      Input_Context__c: 'Case 00001026: Priority High, Status New',
      Output_Result__c: 'Case data retrieved',
      Reasoning__c: 'Fetched the Case to evaluate escalation.',
    },
  },
  {
    name: 'escaping, non-ASCII and metadata',
    fields: {
      Entry_Id__c: '8c0d4c8a-1f2e-4b7a-9f00-000000000002',
      Sequence_Number__c: 1,
      Timestamp_Text__c: '2026-11-09T14:03:28.007Z',
      Agent_Id__c: 'case-escalation-agent',
      Action_Type__c: 'Data_Change',
      Input_Context__c: 'quote " backslash \\ slash / tab \t newline \n return \r bs \b ff \f c1 \u0001 c31 \u001f del \u007f',
      Output_Result__c: 'café ü — 中文 😀 </script> line sep para sep',
      Reasoning__c: 'Escalated: High priority and not yet escalated.',
      Summary__c: 'Set Status to Escalated',
      Target_Record_Id__c: '500gK00001U6r6HQAR',
      Target_Object__c: 'Case',
      Field_Changes__c: '[{"field":"Status","before":"New","after":"Escalated"}]',
      Capture_Method__c: 'Recorded_Action',
      Turn_Number__c: 3,
    },
  },
  {
    name: 'no input, output or reasoning',
    fields: {
      Entry_Id__c: '8c0d4c8a-1f2e-4b7a-9f00-000000000003',
      Sequence_Number__c: 2,
      Timestamp_Text__c: '2026-11-09T14:03:29.000Z',
      Agent_Id__c: 'case-escalation-agent',
      Action_Type__c: 'Decision',
    },
  },
];

function toRecord(f, previousHash) {
  const metadata = {};
  const put = (k, v) => { if (v !== undefined && v !== null) metadata[k] = v; };
  put('summary', f.Summary__c);
  put('targetRecordId', f.Target_Record_Id__c);
  put('targetObject', f.Target_Object__c);
  put('fieldChanges', f.Field_Changes__c);
  put('captureMethod', f.Capture_Method__c);
  put('turnNumber', f.Turn_Number__c);
  return {
    id: f.Entry_Id__c,
    sessionId: SESSION,
    sequenceNumber: f.Sequence_Number__c,
    timestamp: f.Timestamp_Text__c,
    agentId: f.Agent_Id__c,
    actionType: f.Action_Type__c,
    input: f.Input_Context__c != null ? { context: f.Input_Context__c } : {},
    output: f.Output_Result__c != null ? { result: f.Output_Result__c } : {},
    reasoning: f.Reasoning__c,
    metadata: Object.keys(metadata).length ? metadata : undefined,
    previousHash,
  };
}

let previous = null;
for (const v of vectors) {
  v.record = toRecord(v.fields, previous);
  v.previousHash = previous;
  v.canonical = canonicalJson(v.record);
  v.hash = hashActionRecordV2(v.record);
  previous = v.hash;
}
const hashes = vectors.map((v) => v.hash);
const root = computeMerkleRootV2(hashes);
const proof = generateMerkleProofV2(hashes, 2);
const fiveHashes = ['a', 'b', 'c', 'd', 'e'].map((c) => c.repeat(64));
const rootOfFive = computeMerkleRootV2(fiveHashes);

// An Apex string literal for any JavaScript string.
function apex(s) {
  if (s === null || s === undefined) return 'null';
  let out = "'";
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    const ch = s[i];
    if (ch === '\\') out += '\\\\';
    else if (ch === "'") out += "\\'";
    else if (ch === '\n') out += '\\n';
    else if (ch === '\r') out += '\\r';
    else if (ch === '\t') out += '\\t';
    else if (ch === '\b') out += '\\b';
    else if (ch === '\f') out += '\\f';
    else if (c < 0x20 || c > 0x7e) out += '\\u' + c.toString(16).padStart(4, '0');
    else out += ch;
  }
  return out + "'";
}

const fieldOrder = ['Entry_Id__c', 'Sequence_Number__c', 'Timestamp_Text__c', 'Agent_Id__c', 'Action_Type__c',
  'Input_Context__c', 'Output_Result__c', 'Reasoning__c', 'Summary__c', 'Target_Record_Id__c', 'Target_Object__c',
  'Field_Changes__c', 'Capture_Method__c', 'Turn_Number__c'];

const entryBuilders = vectors.map((v, i) => {
  const lines = fieldOrder.filter((k) => v.fields[k] !== undefined).map((k) => {
    const val = v.fields[k];
    return `        e.${k} = ${typeof val === 'number' ? val : apex(val)};`;
  });
  return `    // ${v.name}
    private static Agent_Audit_Record__c entry${i}(String previousHash) {
        Agent_Audit_Record__c e = new Agent_Audit_Record__c();
${lines.join('\n')}
        e.Previous_Hash__c = previousHash;
        return e;
    }`;
}).join('\n\n');

const assertions = vectors.map((v, i) => `        Agent_Audit_Record__c e${i} = entry${i}(${i === 0 ? 'null' : apex(vectors[i - 1].hash)});
        System.assertEquals(${apex(v.canonical)},
            AgentLedgerCanonical.serialize(HashChainService.entryContentV2(e${i}, SESSION)), 'canonical JSON, vector ${i}');
        System.assertEquals(${apex(v.hash)}, HashChainService.hashEntryV2(e${i}, SESSION), 'record hash, vector ${i}');`).join('\n');

const cls = `/**
 * AgentLedgerHashVectorsTest
 *
 * GENERATED by scripts/make-hash-vectors.mjs from @vluthra/agent-ledger ${libVersion}.
 * Do not edit by hand. Checks that Apex produces the same canonical JSON,
 * v2 record hashes, Merkle v2 root and proof as the open-source library, so a
 * run exported from Salesforce verifies with the npm and PyPI verifiers.
 */
@isTest
private class AgentLedgerHashVectorsTest {

    private static final String SESSION = ${apex(SESSION)};

${entryBuilders}

    @isTest
    static void recordHashesMatchTheLibrary() {
${assertions}
    }

    @isTest
    static void merkleRootAndProofMatchTheLibrary() {
        List<String> hashes = new List<String>{ ${hashes.map(apex).join(', ')} };
        System.assertEquals(${apex(root)}, MerkleTreeService.computeMerkleRootV2(hashes), 'root of three (odd node carried up)');
        System.assertEquals(${apex(rootOfFive)}, MerkleTreeService.computeMerkleRootV2(new List<String>{ ${fiveHashes.map(apex).join(', ')} }), 'root of five');

        MerkleTreeService.MerkleProof proof = MerkleTreeService.generateProofV2(hashes, 2);
        System.assertEquals(${proof.siblings.length}, proof.siblings.size(), 'proof length');
${proof.siblings.map((s, i) => `        System.assertEquals(${apex(s.hash)}, proof.siblings[${i}].hash);
        System.assertEquals(${apex(s.position)}, proof.siblings[${i}].position);`).join('\n')}
        System.assert(MerkleTreeService.verifyProofV2(proof), 'proof verifies');
    }
}
`;

const out = path.join(here, '..', 'force-app', 'main', 'default', 'classes', 'AgentLedgerHashVectorsTest.cls');
fs.writeFileSync(out, cls);
fs.writeFileSync(out + '-meta.xml',
  '<?xml version="1.0" encoding="UTF-8"?>\n<ApexClass xmlns="http://soap.sforce.com/2006/04/metadata">\n    <apiVersion>61.0</apiVersion>\n    <status>Active</status>\n</ApexClass>\n');
console.log(`wrote ${out} (library ${libVersion}); root ${root}`);
