# Fixture per il test di non-regressione XML

Valori usati per generare `reference_output.xml`. Per rilanciare il
confronto, l'emittente e il documento nel progetto di test devono avere
esattamente questi valori nei campi che contano (P.IVA, CF, indirizzo,
regime, cliente, riga, aliquota, note).

## Emittente (Impostazioni)

| Campo | Valore |
|---|---|
| Denominazione | TEST - Operatore Prova |
| Partita IVA | 12345678903 *(checksum-valida, non una P.IVA reale assegnata)* |
| Codice Fiscale | *(vuoto)* |
| Regime fiscale | RF19 |
| Indirizzo | Via di Prova 1 |
| CAP | 00100 |
| Comune | Roma |
| Provincia | RM |
| Email | test@example.invalid |
| IBAN | *(vuoto)* |

## Documento (Fattura)

| Campo | Valore |
|---|---|
| Tipo | Fattura |
| Data | 2026-01-15 |
| Aliquota IVA | 22 |
| Note | Test non-regressione XML |

## Cliente (sul documento)

| Campo | Valore |
|---|---|
| Nome / Ragione sociale | Cliente Test SRL |
| P.IVA | 12345678903 |
| Indirizzo | Via del Cliente 2 |
| CAP | 20100 |
| Comune | Milano |
| Provincia | MI |
| Codice SDI | *(vuoto)* |
| PEC | pec@clientetest.invalid |

## Riga

| Descrizione | Quantità | U.M. | Prezzo unitario |
|---|---|---|---|
| Servizio di test | 1 | ora | 100 |

## Riferimento generato

- **Data generazione**: 2026-09-06
- **Numero fattura assegnato**: FATT-006-2026
- **Id documento** (`invoices.id`): `d0b068ab-ebab-42dc-88ed-0034ea16bfe7`

Ristampare l'XML dallo **stesso documento** (stesso id) riproduce lo stesso
output, incluso il numero — vedi `README.md` per i dettagli su cosa cambia
legittimamente se si ricrea il documento da zero altrove.
