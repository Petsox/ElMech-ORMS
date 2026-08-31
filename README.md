# ElMech-ORMS

Simulátor elektromechanického staničního zabezpečovacího zařízení pro Minecraft, běžící na dvou
propojených OpenComputers počítačích (**Stavědlo** a **Dopravní kancelář**), které ovládají prvky
modu [SignalCraft](https://github.com/Petsox/SignalCraft) přes Redstone I/O, Control Panel a
custom OC komponenty z [SignalCraft-Integrations](https://github.com/Petsox/SignalCraft-Integrations)
a [Computronics_Ctyrk4_Edition](https://github.com/Petsox/Computronics_Ctyrk4_Edition).

Tento první krok pokrývá: přestavování výhybek, závěr výměn, návěstní hradlo, hradlová zarážka,
přejezd a hlavní návěstidla pro jedno zhlaví. Posun a sloučení více zhlaví do jednoho systému
zatím nejsou implementované.

Architektura, doménová logika a rozhodnutí jsou popsané v `common/routes.lua`,
`stavedlo/interlocking/switchlock.lua` a `stavedlo/interlocking/gate.lua` -- ty tři soubory jsou
nejlepší místo, kde začít číst kód.

## Instalace

Na obě OpenComputers počítače (potřebují redstone I/O, síťovou/linked kartu a GPU+monitor):

**Stavědlo:**
```
wget -f https://raw.githubusercontent.com/Petsox/ElMech-ORMS/main/stavedlo/installer.lua /tmp/installer.lua && /tmp/installer.lua
```

**Dopravní kancelář:**
```
wget -f https://raw.githubusercontent.com/Petsox/ElMech-ORMS/main/dk/installer.lua /tmp/installer.lua && /tmp/installer.lua
```

(`repoOwner`/`repoName`/`branch` v `installer.lua`/`updater.lua` jsou zatím placeholder hodnoty --
uprav je, až repozitář skutečně vznikne na GitHubu.)

Po instalaci na **obou** počítačích:

1. Vlož do `/home/stavedlo/layout.lua` (resp. `/home/dk/layout.lua`) stejný výstup z
   [ORMS Layout Generatoru](https://petsox.github.io/ORMS-Layout-Generator-Web-Edition/) (viz
   `station.lua` jako příklad).
2. Spusť `setup.lua` -- provede tě mapováním hardwaru na jména/adresy z layoutu a spočítá, kolik
   závěrů výměn je pro dané zhlaví potřeba.
3. Spusť/spouštěj systém příkazem `stavedlo`, resp. `dk`.

## Aktualizace

`updater.lua` na obou strojích porovná git SHA souborů v repu a stáhne jen to, co se změnilo
(mapování a routes.json zůstávají zachované).