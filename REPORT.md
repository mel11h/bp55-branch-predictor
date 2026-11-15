# BP55 — ICsprout 55 nm açık PDK'sı için dallanma tahmin birimi

## 1. 55 nm PDK açık mı?

Evet. **ICsprout55**, Ekim 2025'te Apache 2.0 lisansıyla yayımlandı; depo `openecos-projects/icsprout55-pdk`.
Depoyu klonlayıp içeriğini doğruladım (son commit 30 Ekim 2026):

| İçerik | Durum |
|---|---|
| Standart hücreler (`ics55_LLSC_H7C`, 7‑track, HVT/RVT/LVT) | Var: her VT için 747 hücre; Liberty (7 köşe), LEF, CDL, Verilog, GDS |
| IO kütüphanesi, DRC/LVS kuralları, cihaz modelleri | Var |
| **SRAM / bellek derleyicisi, PLL** | **Yok** (yol haritasında) |
| Olgunluk | Proje kendi belgesinde "preview release" diyor |

Tasarımı belirleyen kısıt SRAM'in olmaması: tahminleyicinin bütün tabloları flip‑flop dizisi olmak zorunda.
En küçük flop (`DFFQX0P5H7R`) 6,16 µm², yani 1 Kbit durum okuma/yazma mantığıyla birlikte yaklaşık 0,01 mm².
Bu yüzden bütçeyi ~8 Kbit'te tuttum; SRAM tabanlı tasarımlardaki 30–250 Kbit burada gerçekçi değil.

## 2. Hedef işlemci ve varsayımlar

- RV32IM, tek komut/çevrim, sıralı (in‑order), 6 aşama: IF1 · IF2 · ID · EX · MEM · WB.
- Dallanma EX'te çözülür: yanlış tahmin cezası **3 çevrim**. ID'den yeniden yönlendirme (BTB'de olmayan `jal`, tahmini alınan dal) **2 çevrim**.
- Tahmin IF1'de tek çevrimde yapılır; doğru tahmin edilen alınan dalda boşluk (bubble) yoktur.

## 3. Mimari

| Bileşen | Boyut | Bit | Görev |
|---|---|---|---|
| BTB | 128 giriş, doğrudan eşlemeli: geçerli + 8 bit etiket + 3 bit tür + 18 bit hedef | 3840 | IF1'de "bu PC dallanma mı, hedefi ne" |
| Bimodal | 512 × 2 bit | 1024 | TAGE taban tahmini |
| TAGE | 3 tablo × 64 giriş × (7 bit etiket + 3 bit sayaç + 1 bit u); geçmiş 5 / 12 / 28 | 2112 (+43 denetim) | Yön tahmini |
| ITC | 32 giriş × (geçerli + 8 bit etiket + 18 bit hedef), 6 bit hedef geçmişi | 870 | Dolaylı atlamalar (switch, fonksiyon işaretçisi) |
| RAS | 8 × 30 bit | 243 | Dönüş adresleri |
| **Toplam** | | **8132** | |

Önemli tasarım kararları:

- **Tek çevrim, override yok.** Tablolar küçük ve flop tabanlı olduğu için bütün arama tek çevrime sığıyor (bkz. §6); iki kademeli tahminleyicinin ek boşluğu ve karmaşıklığı gerekmiyor.
- **Katlanmış geçmiş kombinasyonel.** Geçmiş en fazla 28 bit olduğundan indeks/etiket katlaması doğrudan GHR'den XOR ağacıyla üretiliyor; yanlış tahminde yalnızca GHR'yi geri yüklemek yetiyor.
- **Süzülmüş geçmiş.** GHR'ye yalnızca BTB'de bulunan ya da alınan koşullu dallar girer. Bu, IF1'de bilinmeyen dallar için geç geçmiş ekleme sorununu ortadan kaldırıyor; ideal "her dal" geçmişine göre kayıp 0,1 MPKI'nin altında.
- **Flop dizisinin getirisi.** `u` bitlerinin periyodik sıfırlanması tek çevrimde yapılıyor; yük bitlerinde reset yok (küçük flop), yazma izinleri saat kapılama hücresine (ICG) çevriliyor.
- **Onarım.** Her aramada 67 bitlik denetim noktası (GHR, hedef geçmişi, RAS işaretçisi + tepe girişi) alınır; yeniden yönlendirmede geri yüklenir. Eğitim, aramada yakalanan 92 bitlik meta veriyle EX'te yapılır, ikinci okuma kapısı gerekmez.

RTL: `rtl/bp55.sv` (~270 satır). Bit‑doğru referans model: `sim/bp_model.h`.

## 4. Yöntem

1. **İş yükleri:** CoreMark, Embench‑IoT'tan 18 program, ve dolaylı atlama / çağrı‑dönüş davranışını zorlamak için yazdığım iki program (`interp`, `recurse`). Clang ile RV32IM'e derlendi.
2. **İz üretimi:** kendi yazdığım RV32IM komut kümesi simülatörü (`iss/rvsim.c`). 21 programın hepsi kendi doğrulamasından geçti. Toplam ~300 M komut, ~42 M dallanma.
3. **Model:** izle sürülen C++ simülatörü; her dal için boru hattı cezasını (0 / 2 / 3 çevrim) hesaplar. Dallanma olmayan PC'ler de BTB'ye sorulur.
4. **Tarama:** BTB / bimodal / TAGE / ITC boyutları üzerinde 300 konfigürasyon, ardından seçilen nokta çevresinde 26 ince ayar.
5. **RTL doğrulama:** Yosys CXXRTL ile RTL ↔ model ko‑simülasyonu.
6. **Sentez:** Yosys + ABC, ICsprout55 RVT Liberty.

Metrik: MPKI = 1000 komut başına EX'te çözülen yanlış tahmin. "Kayıp" = 1000 komut başına dallanma kaynaklı ek çevrim (3·yanlış tahmin + 2·ID yönlendirmesi).

## 5. Performans

### 5.1 Özet (21 izin aritmetik ortalaması)

| Konfigürasyon | Bit | MPKI | Yön doğruluğu | Kayıp (çevrim/kI) | CPI |
|---|---|---|---|---|---|
| Tahmin yok | 0 | 81,7 | — | 269,0 | 1,269 |
| Yalnız BTB (128) | 4083 | 71,0 | — | 213,9 | 1,214 |
| BTB + bimodal + RAS + ITC | 5977 | 16,07 | %89,85 | 55,7 | 1,056 |
| BTB + gshare + RAS + ITC | 9059 | 10,80 | %93,35 | 40,7 | 1,041 |
| **BP55** | **8132** | **9,34** | **%94,60** | **36,7** | **1,037** |
| BP55, 16 Kbit ölçeği | 17044 | 8,51 | %95,16 | 32,1 | 1,032 |
| TAGE, 123 Kbit (SRAM sınıfı, referans) | 122952 | 5,73 | %96,44 | 18,1 | 1,018 |

- Tahminsiz çekirdeğe göre **%22 daha hızlı** (CPI 1,269 → 1,037). Yön tahmini olmayan yalnızca BTB'li tabana (CPI 1,214) göre hızlanma %17'dir.
- Bimodal'e göre MPKI %42 düşük; gshare'e göre %10 daha az bitle MPKI %13,5 düşük.
- Kısa boru hattında gshare'e göre CPI farkı küçük (%0,4). Ceza büyüdükçe fark açılıyor: EX cezası 12 çevrim olan bir çekirdekte CPI 1,146'ya karşı 1,130 (4 çevrimlik çözme yönlendirmesi varsayımıyla; betiği saklanmadı).
- Alınan dalların %90,5'i sıfır boşlukla tahmin ediliyor.

![Pareto](results/pareto.png)

### 5.2 Bileşen katkısı

| Değişiklik | MPKI | Kayıp (çevrim/kI) |
|---|---|---|
| BP55 | 9,34 | 36,7 |
| ITC yok (−870 bit) | 10,70 | 40,8 |
| RAS yok (−243 bit) | 10,23 | 38,7 |
| BTB 64 giriş (−1920 bit) | 9,52 | 42,7 |
| Tablo güncellemesi 2 dal gecikmeli | 9,59 | 37,6 |

Güncelleme gecikmesine duyarlılık düşük, yani EX'te eğitim yeterli. Bit başına en verimli bileşen RAS, sonra ITC.

![Bileşenler](results/ladder.png)

### 5.3 Kıyaslama bazında

![MPKI](results/mpki_bench.png)

| Program | Tahminsiz MPKI | bimodal | gshare 9K | BP55 | TAGE 123K | BP55 hızlanma (tahminsize göre) |
|---|---|---|---|---|---|---|
| coremark | 105,5 | 14,85 | 13,66 | 9,80 | 3,24 | 1,29× |
| nsichneu | 79,8 | 36,74 | 10,17 | 2,02 | 0,33 | 1,10× |
| slre | 116,5 | 17,33 | 11,13 | 7,03 | 1,34 | 1,31× |
| ud | 57,1 | 39,97 | 3,51 | 2,39 | 0,22 | 1,19× |
| huffbench | 124,5 | 25,41 | 17,96 | 18,13 | 7,97 | 1,34× |
| sglib-combined | 114,4 | 40,49 | 40,50 | 33,95 | 16,58 | 1,24× |
| qrduino | 51,7 | 31,41 | 25,77 | 24,65 | 19,40 | 1,11× |
| xgboost | 46,5 | 37,59 | 33,62 | 35,48 | 33,15 | 1,10× |
| interp | 54,2 | 27,41 | 27,39 | 24,28 | 13,06 | 1,21× |
| tarfind | 198,4 | 1,72 | 1,96 | 1,68 | 1,61 | 1,59× |

Tam tablo `results/final.csv` içinde. Gözlemler:

- `xgboost` ve `recurse` programlarında 123 Kbit TAGE bile yardımcı olmuyor (%7 ve %2 azalma); `qrduino`'da ise %21 azaltıyor. Burada kazanç tahminleyiciden değil, dalsız kodlamadan gelir.
- `xgboost`, `huffbench` ve `depthconv`'da BP55, gshare'in hafifçe gerisinde: `huffbench` ve `depthconv`'da 64 girişli etiketli tablolar taşıyor; `xgboost`'ta daha büyük tablolar da yardımcı olmuyor.
- Tasarım noktası, sonuçların raporlandığı aynı 21 programda, ayrılmış test kümesi olmadan yaklaşık 370 yapılandırma arasından seçildi; gshare'e farkın çoğu beş programdan geliyor.
- `nsichneu`'da BP55'in MPKI'si çok düşük ama CPI kaybı yüksek (129 çevrim/kI): program binlerce farklı daldan oluşuyor, 128 girişli BTB yetmiyor ve dallar ID'den yönlendiriliyor.
- Kalan yanlış tahminlerin dağılımı: koşullu %80, dolaylı atlama/çağrı %19, dönüş %1.

## 6. Fiziksel sonuçlar (ICsprout55, RVT, sentez sonrası)

| | Değer |
|---|---|
| Flip‑flop | 8132 (7920 resetsiz, 212 resetli) |
| Hücre alanı, saat kapılamasız | 97 247 µm² |
| **Hücre alanı, saat kapılamalı (364 ICG)** | **81 627 µm² ≈ 0,082 mm²** (flop %62, mantık %35, ICG %3) |
| Kritik yol, TT 1,2 V 25 °C | 1,33 ns (`f_pc` → BTB/TAGE okuma → meta) |
| Kritik yol, SS 1,08 V 125 °C | 2,47 ns (`ghr` → TAGE → `f_taken`) |

%70 yerleşim yoğunluğuyla yaklaşık 0,12 mm². Zamanlama rakamları yalnızca kombinasyonel gecikmedir: tel yükü, flop clk‑to‑Q/setup ve sonraki‑PC çoklayıcısı dahil değil.
İlk sürümde buradan SS'de 250–280 MHz, TT'de ~450 MHz tahmin etmiştim; **bu tahmin iyimserdi.** Yerleştirme‑yönlendirme sonrası rakamlar §8'da: blok düzeyinde SS'de 161 MHz (6,2 ns), TT'de ~267 MHz.

## 7. Doğrulama durumu

| Adım | Sonuç |
|---|---|
| ISS doğruluğu | 21 programın tamamı kendi sonuç denetiminden geçti |
| RTL ↔ model, anında güncelleme | 63,4 M arama (iz başına ilk 300 K dal + aradaki tüm PC'ler), **0 uyuşmazlık** |
| RTL ↔ model, 2 dal gecikmeli güncelleme | 63,4 M arama, **0 uyuşmazlık** |
| Sentez | Yosys/ABC ile hatasız eşlendi |

Yapılmayanlar ve sınırlar:

- **Kapı seviyesi simülasyon yok.** Sentezlenmiş ve yönlendirilmiş netlistler simüle edilmedi; işlevsel doğrulama RTL düzeyindedir. (Yerleştirme‑yönlendirme sonradan yapıldı, bkz. §8.)
- **Çekirdeğe entegre edilmedi.** Ko‑simülasyon izle sürülüyor; yanlış yoldaki (wrong‑path) aramalar ve onarımın gerçek boru hattı zamanlaması denenmedi.
- **BTB çakışması hiç tetiklenmedi.** Programlar küçük (en fazla onlarca KB) olduğundan etiket çakışması ve "hayalet dal" yolu 0 kez çalıştı; bu RTL yolu test edilmemiş sayılmalı. Aynı nedenle 8 bit etiket ve 18 bit hedef genişliği ölçümle değil varsayımla seçildi.
- **İş yükleri gömülü sınıf.** Sonuçlar SPEC benzeri büyük kod tabanlarına taşınmaz; orada BTB ve tablo boyutları yetersiz kalır.
- CPI yalnızca dallanma kaybını içerir; önbellek ıskaları ve load‑use beklemeleri yok.

## 8. Fiziksel tasarım (yerleştirme‑yönlendirme)

Araçlar: OpenROAD 26Q3 (nixpkgs), KLayout 0.30 (DEF + hücre GDS birleştirme ve görseller). Akış: `pnr/1_place.tcl` → `pnr/2_cts_route.tcl` (yalnız saat ağacı kısmı) → `pnr/3_route.tcl` → `pnr/def2gds.py`.

| | Değer |
|---|---|
| Kalıp (die) | 430,5 × 430,5 µm = **0,185 mm²** |
| Çekirdek alanı / doluluk | 0,176 mm² / %65 (dolgu hücreleri hariç) |
| Hücre alanı (dolgu hariç) | 113 653 µm² (sentez: 97 247 µm²; fark saat ağacı, hold ve zamanlama tamponları) |
| Hücre sayısı | 81 398 (dolgu ve tap dahil); 8132 flop, 2596 saat tamponu/evirici, 4024 zamanlama onarım tamponu |
| Güç ağı | MET1 raylar, MET4 dikey + MET5 yatay şeritler (0,6 µm, 28 µm aralık) |
| Sinyal yönlendirme | MET2–MET5, toplam tel 900 mm, 162 034 via |
| Yönlendirici kural ihlali | **0** |
| Anten ihlali | **0** |
| Saat ağacı | gecikme ~1,2 ns (SS), skew ~0,16 ns |
| Güç (TT, 167 MHz, varsayılan aktivite) | 33 mW; %48 flop iç gücü, %30 saat ağacı |

Zamanlama (6,0 ns saat, giriş/çıkış bütçesi 0,5 + 0,5 ns, setup belirsizliği 0,10 ns):

| Köşe | Setup payı | Hold payı |
|---|---|---|
| SS, 1,08 V, 125 °C | **−0,10 ns** (`f_taken` çıkışı) | +0,02 ns |
| TT, 1,2 V, 25 °C | +2,26 ns | +0,12 ns |
| FF, 1,32 V, −40 °C | +3,22 ns | +0,06 ns |

Buna göre blok düzeyinde SS'de 6,2 ns (161 MHz) ile kapanıyor; TT'de ~3,7 ns (267 MHz). SS'deki kritik yol flop → çıkış yoludur ve 1,2 ns'lik saat ağacı gecikmesini içerir; çıkışı yakalayan PC flop'u aynı ağaçta olacağı için çekirdeğe gömüldüğünde bu yol kısalır.

Akış sırasında ortaya çıkanlar:

- **Saat kapılama fiziksel tasarımda kullanılamadı.** PDK Liberty dosyasında ICG hücrelerinin `clock_gate_*` pin öznitelikleri yok; OpenROAD saat ağacını ICG'lerin arkasına dengeleyemedi (saat gecikmesi 2,4 ns, kapanmayan hold ihlalleri). Layout saat kapılamasız netlistle yapıldı. Bedeli: +%19 hücre alanı ve yüksek güç (flop'lar her çevrim saatleniyor).
- **Sentez zamanlaması yanıltıcıydı.** ABC'nin telsiz 2,47 ns'lik SS tahmini (saat‑çıkış gecikmesi hariç), yönlendirilmiş layoutta saat‑çıkış gecikmesi dahil ~4,3 ns'ye çıktı: flop dizilerinin adres hatları binlerce çoklayıcıyı sürüyor ve derin tampon ağaçları gerektiriyor.
- Hold onarımı 2.314 ihlalli uç nokta buldu ve 363 hold tamponu ekledi; en kötüleri giriş‑flop yollarında. Alan artışının çoğu yerleştirme sırasındaki zamanlama onarım tamponlarından ve saat ağacı hücrelerinden geliyor.

Fiziksel tasarımın sınırları:

- **İmza (sign‑off) DRC ve LVS çalıştırılmadı.** PDK'nın kural dosyaları Calibre formatında; açık kaynak karşılığı yok. "0 ihlal" yalnızca yönlendiricinin LEF kurallarına göre denetimidir.
- **Parazit çıkarımı yok.** PDK'da OpenRCX kural dosyası bulunmadığından zamanlama, global yönlendirme tabanlı RC tahminiyle raporlandı; detaylı yönlendirme sonrası gerçek çıkarım değil.
- Layout 6,0 ns hedefini SS'de 0,10 ns ile kaçırıyor (yerleştirme günlüğü, yerleşimin 5,0 ns saatle yapıldığını gösteriyor; depodaki `bp55.sdc` 6,0 ns); **6,2 ns saatle (161 MHz) tüm köşelerde kapanıyor** (aşağıdaki "6,2 ns denemesi" bölümü). SS hold payı 6,2 ns'de de yalnızca ~0,00 ns; pay yok denecek kadar az.
- IR düşümü ve elektromigrasyon analizi yapılmadı; güç rakamı varsayılan anahtarlama aktivitesiyle.

### 6,2 ns denemesi

Saat hedefini 6,2 ns'ye gevşetip akışı baştan koşturmak sorunu **çözmedi**: araç daha gevşek hedefe göre daha az optimize etti ve SS'de yine açık kaldı.

| Koşu | SS setup payı | SS hold payı | TT setup payı | Yönlendirici / anten ihlali |
|---|---|---|---|---|
| 6,0 ns hedefiyle optimize, 6,0 ns'de denetim | −0,10 ns | +0,02 ns | +2,26 ns | 0 / 0 |
| 6,2 ns hedefiyle optimize, 6,2 ns'de denetim (`pnr/run_6p2/`) | −0,15 ns | +0,02 ns | +2,38 ns | 0 / 0 |
| **6,0 ns hedefiyle optimize, 6,2 ns'de denetim** (`pnr/signoff/`) | **+0,10 ns** | 0,00 ns | +2,47 ns | 0 / 0 |

Her iki koşuda da kalan tek ihlal `f_taken` çıkışıdır; onarım hedefin ~0,1 ns gerisinde duruyor. Bu yüzden nihai layout olarak 6,0 ns hedefiyle üretilen sürüm korundu (depodaki GDS/DEF/netlist) ve 6,2 ns saatle yeniden zamanlandı. Yeniden zamanlama, yönlendirilmiş DEF'in yerleşimi üzerinde global yönlendirmenin baştan koşturulmasıyla yapıldı; 6,0 ns'deki −0,10 ns sonucu aynen yeniden üretildi. Pratik kural: bu akışta imza saatinden daha sıkı bir hedefle optimize etmek gerekiyor; ne kadar sıkı olması gerektiği ayrıca ölçülmedi. Not: giriş/çıkış gecikmeleri ideal saate göre tanımlı, flop'lar ise ~1,2 ns saat ağacı gecikmesi görüyor; 161 MHz ve sıfır hold payı bu kısıttan etkileniyor.

Çıktılar: `pnr/bp55.gds` (son GDSII), `pnr/5_final.def`, `pnr/5_final.v`, `pnr/layout_full.png`, `pnr/layout_zoom.png`, `pnr/layout_pdn_m4m5.png`.

## 9. Yeniden üretim

```bash
cd bench && GSF=4 CM_IT=60 ./build.sh        # derle + izleri üret
cd ../sim && g++ -O2 -std=c++17 -o bpsim bpsim.cc
./bpsim BP55 LB=7 LBIM=9 LI=5 HT=6 NT=3 LT=6 TT=7 hist=5,12,28 -- ../traces/*.trc | python3 summ.py /dev/stdin
./cosim 300000 0 1 ../traces/*.trc            # RTL ↔ model
cd ../syn && ./synth.sh tt_cg tt.lib 2500 1   # sentez
cd ../syn && ./synth.sh tt_nocg tt.lib 2500 0 # layout için saat kapılamasız netlist (sonra pnr/bp55_pnr_in.v'ye temizlenir)
cd ../pnr && openroad -exit 1_place.tcl && openroad -exit 2_cts.tcl && openroad -exit 3_route.tcl
python3 def2gds.py && python3 render.py      # GDS + görseller
```

Dizinler: `rtl/` RTL · `sim/` model, sürücü, ko‑simülasyon · `iss/` RV32IM simülatörü · `bench/` iş yükleri · `syn/` sentez betikleri ve netlist · `results/` CSV, günlükler, grafikler · `pnr/` yerleştirme‑yönlendirme betikleri, DEF, GDS, görseller · `pdk/` ICsprout55.

Kaynaklar: [ICsprout55 belgeleri](https://icsprout55-pdk-en.readthedocs.io/en/latest/) · [yayın duyurusu](https://website-src-mkdocs.vercel.app/en/news/20251020_icsprout55_pdk_release) · [depo](https://github.com/openecos-projects/icsprout55-pdk)
