# NFC

*13.56 MHz, a few centimetres*

```text
phone (reader) )))  the field powers the tag
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
