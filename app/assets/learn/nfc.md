# NFC

*13.56 MHz, a few centimetres*

```text
phone (reader) )))  field powers the tag
               ◀──  tag answers
                    (load modulation)
```

## Layers

| Layer | What |
|---|---|
| ISO 14443-A/B | radio + anti-collision (most tags) |
| NFC-A tag types | NTAG213/215/216 (Type 2), MIFARE Classic (needs keys) |
| NDEF | the message format every phone understands |

## NDEF record

```text
[MB ME CF SR IL TNF][type len][payload len]
[id len?][type][id][payload]
```

- TNF 1 = well-known: `"T"` text, `"U"` URI.
- URI prefix byte: `04` = `https://`.
- TNF 2 = media type: `application/vnd.wfa.wsc` is a Wi-Fi network
  (SSID, auth, key as TLVs). Android offers to join it.
- TNF 0 = empty record: that is what **Erase** writes.

## Which tag is it?

```text
tap ─▶ ATQA + SAK (free, every NFC-A tag)
SAK 00 Type 2: ask GET_VERSION (60)
       ─▶ NTAG213 / 215 / 216
SAK 08 MIFARE Classic 1K (sector keys)
SAK 20 ISO-DEP: APDUs (DESFire, cards)
```

GET_VERSION reply byte 6 is the storage size: `0f` NTAG213 (144 B),
`11` NTAG215 (504 B), `13` NTAG216 (888 B).

## Lock

**Lock** sets the lock bits: one-time-programmable, so the tag stays
read-only for good. Erase and Write then fail on that tag.

## UID

4, 7 or 10 bytes, readable by anyone and easy to clone: **never** use it
alone as a door key.

## Gotchas

- Metal behind a tag kills the field.
- Bank cards: no NDEF (ISO-DEP, encrypted).
- Writing is permanent if the tag is locked.

## Try

Write a URI, read it back, and compare the bytes in Inside with the
record layout.
