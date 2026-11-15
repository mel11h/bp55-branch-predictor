# BP55

ICsprout 55 nm açık PDK'sı için dallanma tahmin birimi. Ayrıntılar: REPORT.md

Bu depoda yer almayanlar (yeniden indirilebilir / üretilebilir):
- pdk/                 git clone https://github.com/openecos-projects/icsprout55-pdk  (+ RVT liberty arşivi, release sayfasından)
- bench/coremark       git clone https://github.com/eembc/coremark
- bench/embench-iot    git clone https://github.com/embench/embench-iot
- traces/              cd bench && GSF=4 CM_IT=60 ./build.sh
- derlenmiş ikililer, sim/bp55_rtl.cc (yosys write_cxxrtl çıktısı), sentez günlükleri

Araç kurulumu (hiçbiri arşivde değil):
- Yosys:    pip install pyosys            (0.71 kullanıldı)
- OpenROAD: nix build nixpkgs#openroad    (26Q3 kullanıldı; PyPI'daki "openroad" paketi KULLANILMADI)
- KLayout:  pip install klayout           (0.30 kullanıldı)
- Derleyici: clang 18 (riscv32 hedefi) + lld

Not: pnr/2_cts_route.tcl'nin yönlendirme kısmı pnr/3_route.tcl ile değiştirildi; 2'den yalnızca
2_cts.odb'ye kadar olan bölüm kullanılır. pnr/*.odb ara veritabanları arşivde yok.

Büyük çıktılar gzip ile sıkıştırılmıştır: pnr/bp55.gds.gz (son GDSII), pnr/5_final.def.gz, pnr/5_final.v.gz, syn/tt_cg.v.gz, syn/tt_nocg.v.gz.
