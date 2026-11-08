import 'dart:convert';
import 'dart:typed_data';

import 'ndef_view.dart';

/// Record payloads written by hand (NFC Forum RTD and Wi-Fi Alliance WSC),
/// so the Inside tab can explain every byte the tool writes. The tool
/// wraps them in nfc_manager's NdefRecord.

/// URI record payload: [prefix code][rest of the URI]. Uses the longest
/// known prefix, so "https://www.x.com" costs 1 byte for "https://www.".
Uint8List uriPayload(String uri) {
  var bestCode = 0;
  for (final entry in ndefUriPrefixes.entries) {
    if (uri.startsWith(entry.value) && entry.value.length > ndefUriPrefixes[bestCode]!.length) bestCode = entry.key;
  }
  return Uint8List.fromList([bestCode, ...utf8.encode(uri.substring(ndefUriPrefixes[bestCode]!.length))]);
}

/// Text record payload: [status: UTF-8, language length][language][text].
Uint8List textPayload(String text, {String language = 'en'}) {
  final languageBytes = ascii.encode(language);
  return Uint8List.fromList([languageBytes.length & 0x3f, ...languageBytes, ...utf8.encode(text)]);
}

/// MIME type Android reads as "join this Wi-Fi network".
const wifiMimeType = 'application/vnd.wfa.wsc';

/// WSC attribute ids (Wi-Fi Simple Configuration spec, TLV: id 2, length 2).
const wscCredential = 0x100E;
const wscNetworkIndex = 0x1026;
const wscSsid = 0x1045;
const wscAuthType = 0x1003;
const wscEncryptionType = 0x100F;
const wscNetworkKey = 0x1027;
const wscMacAddress = 0x1020;

/// Wi-Fi credential payload: one Credential TLV holding SSID, auth,
/// encryption and key. An empty password means an open network.
Uint8List wifiPayload({required String ssid, required String password}) {
  final isOpen = password.isEmpty;
  final credential = [
    ..._tlv(wscNetworkIndex, [0x01]),
    ..._tlv(wscSsid, utf8.encode(ssid)),
    ..._tlv(wscAuthType, isOpen ? [0x00, 0x01] : [0x00, 0x20]), // open / WPA2-Personal
    ..._tlv(wscEncryptionType, isOpen ? [0x00, 0x01] : [0x00, 0x08]), // none / AES
    ..._tlv(wscNetworkKey, utf8.encode(password)),
    ..._tlv(wscMacAddress, List.filled(6, 0xff)), // any access point
  ];
  return Uint8List.fromList(_tlv(wscCredential, credential));
}

List<int> _tlv(int id, List<int> value) => [id >> 8, id & 0xff, value.length >> 8, value.length & 0xff, ...value];

/// The WSC TLVs inside [bytes], one level deep into the Credential.
/// Stops quietly at a cut-off TLV: a summary must not throw.
Map<int, Uint8List> wscAttributes(Uint8List bytes) {
  final found = <int, Uint8List>{};
  var offset = 0;
  while (offset + 4 <= bytes.length) {
    final id = bytes[offset] << 8 | bytes[offset + 1];
    final length = bytes[offset + 2] << 8 | bytes[offset + 3];
    if (offset + 4 + length > bytes.length) break;
    final value = Uint8List.sublistView(bytes, offset + 4, offset + 4 + length);
    if (id == wscCredential) {
      found.addAll(wscAttributes(value));
    } else {
      found[id] = value;
    }
    offset += 4 + length;
  }
  return found;
}
