"""ICsprout55 back-end stack used by the BP55 extraction deck, with the source of every number.

What the PDK documents (pdk/ = github.com/openecos-projects/icsprout55-pdk):
  [DRM]  pdk/docs/ZJCX 55nm Design Rule Manual_V1.1.9.pdf
         p.4  : 55 nm is a 0.9x linear optical shrink of the 65 nm rules; layout (and the
                LEF/DEF) is drawn at 65 nm size, the GDS is shrunk at mask making.
         p.13 : cross-section 3.2.3: layer ORDER and MATERIALS only, no thicknesses:
                ILD (PMD), then per 1x level an "a" film = NDC and a "b" film = BD
                (Black Diamond low-k); the 4x top level sits in "c" = SiN and "d" = PEOX;
                passivation SiN/TEOS. W/P: MET1 0.09/0.18, METx 0.1/0.2, T4M2 0.4/0.8.
         p.105: only POLY (1000 A) and RDL/AL pad (14500 A) thicknesses are given.
  [LVS]  pdk/pv/LVS/ICsprout_CalLVS_55LLULP1233_REV1_0_OS.lvs
         l.188/26 : scale_value 0.9 with HALF_NODE TRUE (default)
         l.249-293: metal sheet resistance rsh_rm1 0.1122, rsh_rm2..8 0.0914,
                    rsh_rtm1 0.0239 (T4M1), rsh_rtm2 0.0177 (T4M2) ohm/sq, and width
                    bias dw_rm1 0.012485 um, dw_rm2..8 0.01246 um
         l.3161-3173: metal resistor model R = (L*0.9 - 2 dl) * Rs / (W*0.9 - 2 dw)
  [LEF]  pdk/prtech/techLEF/N551P6M_ecos.lef: RPERSQ (same as LVS), CPERSQDIST and
         EDGECAPACITANCE per layer (one nominal set), via RESISTANCE 2.5 ohm per cut.
         No THICKNESS / HEIGHT / dielectric data.
  [LIB]  Liberty corner names ss_rcworst / typ / ff_rcbest name RC corners, but the PDK
         has no RC-corner data at all (no ITF, QRC tech, nxtgrd, captable).

What is ASSUMED here (not in the PDK; typical published 65 nm Cu/low-k values):
  A1 metal thickness from sheet resistance, t = rho_eff / Rs with rho_eff = 2.0 uOhm cm
     (wide damascene Cu incl. barrier, 25 C): MET1 0.178 um, MET2-5 0.219 um,
     T4M2 0.837 um (T4M2 uses rsh_rtm1 0.0239, the LEF RPERSQ of T4M2).
  A2 dielectric constants: BD 2.9, NDC 4.9, SiN 7.0, PEOX/TEOS/ILD oxide 4.1.
  A3 film thicknesses: ILD (substrate/STI top to IMD1a) 0.30 um, every NDC cap 0.05 um,
     every 1x via 0.20 um, SiN under the 4x level 0.05 um, T4V2 0.60 um.
  A4 the dw of the LVS resistor model is a non-conducting liner: the conductor for R is
     W*0.9 - 2 dw wide, while the capacitor plate is the full W*0.9.
  A5 RC corners (no spread in the PDK): rcworst = silicon width -8 nm, metal thickness
     -10 %, dielectric films -10 %; rcbest = +8 nm, +10 %, +10 %; typical nominal.
     Temperature of the paired cell corner applied to wire R with TCR 3.0e-3 /K
     (ss 125 C, tt 25 C, ff -40 C).
"""

SHRINK = 0.9
RHO_EFF = 2.0e-2  # ohm um (2.0 uOhm cm)
TCR = 3.0e-3      # 1/K

K_BD, K_NDC, K_SIN, K_OX = 2.9, 4.9, 7.0, 4.1

RS = {"MET1": 0.1122, "MET2": 0.0914, "MET3": 0.0914, "MET4": 0.0914, "MET5": 0.0914, "T4M2": 0.0239}
DW = {"MET1": 0.012485, "MET2": 0.01246, "MET3": 0.01246, "MET4": 0.01246, "MET5": 0.01246, "T4M2": 0.0}
ORDER = ["MET1", "MET2", "MET3", "MET4", "MET5", "T4M2"]

CORNERS = {
    #            dW (um, silicon), thickness factor, dielectric factor, temperature
    "typ":     dict(dw=0.0, tf=1.00, df=1.00, temp=25.0),
    "rcworst": dict(dw=-0.008, tf=0.90, df=0.90, temp=125.0),
    "rcbest":  dict(dw=+0.008, tf=1.10, df=1.10, temp=-40.0),
}


class Stack:
    def __init__(self, corner="typ"):
        c = CORNERS[corner]
        self.corner = corner
        self.dw = c["dw"]
        self.temp = c["temp"]
        tf, df = c["tf"], c["df"]
        ild, ndc, via, sin, t4v = 0.30 * df, 0.05 * df, 0.20 * df, 0.05 * df, 0.60 * df
        thick = {m: RHO_EFF / RS[m] * tf for m in ORDER}
        self.thick = thick
        diel = []
        z = 0.0
        diel.append((z, z + ild, K_OX)); z += ild
        self.zb = {}
        # MET1: NDC (IMD1a) then BD (IMD1b) holding the M1 trench
        diel.append((z, z + ndc, K_NDC)); z += ndc
        self.zb["MET1"] = z
        diel.append((z, z + thick["MET1"], K_BD)); z += thick["MET1"]
        for m in ["MET2", "MET3", "MET4", "MET5"]:
            diel.append((z, z + ndc, K_NDC)); z += ndc
            diel.append((z, z + via + thick[m], K_BD))
            self.zb[m] = z + via
            z += via + thick[m]
        # 4x level: SiN cap ("T4M2 c") then PEOX ("T4M2 d") for T4V2 + T4M2
        diel.append((z, z + sin, K_SIN)); z += sin
        self.zb["T4M2"] = z + t4v
        ztop = z + t4v + thick["T4M2"] + 3.0
        diel.append((z, ztop, K_OX))
        self.diel = diel

    def z(self, layer):
        return self.zb[layer], self.zb[layer] + self.thick[layer]

    def si_width(self, drawn_w):
        """Silicon width of a drawn wire (capacitor plate)."""
        return drawn_w * SHRINK + self.dw

    def r_per_drawn_um(self, layer, drawn_w):
        """Wire resistance per drawn micrometre at the corner temperature."""
        rs = RS[layer] * (RHO_EFF / RS[layer]) / self.thick[layer]  # Rs scaled by thickness
        weff = drawn_w * SHRINK + self.dw - 2.0 * DW[layer]
        return rs * SHRINK / weff * (1.0 + TCR * (self.temp - 25.0))

    def describe(self):
        lines = [f"corner {self.corner}: dW {self.dw:+.3f} um, T {self.temp} C"]
        for m in ORDER:
            z0, z1 = self.z(m)
            lines.append(f"  {m:5s} z {z0:.3f}-{z1:.3f} um  t {self.thick[m]:.3f} um")
        for z0, z1, e in self.diel:
            lines.append(f"  dielectric {z0:.3f}-{z1:.3f} um k={e}")
        return "\n".join(lines)
