# Produce an Icarus-12-compatible copy of rtl/bp55.sv (unrolls the two loops that index tu[i][...] with i).
import sys
s = open(sys.argv[1]).read()
s = s.replace("      t_u[i]   = tu[i][t_idx[i]];\n", "")
s = s.replace("    t_ctr[0] = tctr0", "    t_u[0] = tu[0][t_idx[0]]; t_u[1] = tu[1][t_idx[1]]; t_u[2] = tu[2][t_idx[2]];\n    t_ctr[0] = tctr0", 1)
old = """    for (int i = 0; i < NT; i++) begin
      if (u_wrap) tu[i] <= '0;                                    // periodic graceful reset (free with flop arrays)
      else if (alloc[i] | decay[i]) tu[i][m_idx[i]] <= 1'b0;
      else if (isprov[i] && (u_provp != u_altp)) tu[i][m_idx[i]] <= (u_provp == u_taken);
    end"""
assert old in s
new = "".join(f"""
      if (u_wrap) tu[{i}] <= '0;
      else if (alloc[{i}] | decay[{i}]) tu[{i}][m_idx[{i}]] <= 1'b0;
      else if (isprov[{i}] && (u_provp != u_altp)) tu[{i}][m_idx[{i}]] <= (u_provp == u_taken);""" for i in range(3))
s = s.replace(old, new)
open(sys.argv[2], "w").write(s)
