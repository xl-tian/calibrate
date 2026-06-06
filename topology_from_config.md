# Zaratan network topology (from Slurm topology.conf + IB queries)

Technology: Mellanox/NVIDIA HDR InfiniBand (ConnectX-6, MT4123). 2-level fat tree.
Node HCA link: HDR100 = 2X HDR (50 Gb/s/lane x2) = 100 Gb/s.
Switch OUI b8:ce:f6 = NVIDIA/Mellanox (likely QM87xx Quantum HDR, 40x HDR200 ports).
Separate Ethernet: 2x100GbE LACP bond (200 Gb/s) for storage/mgmt.

## Leaf switches (Level 0) and node counts
SwitchName=b8cef60300d85b40 Nodes=gpu-a6-[2-9],compute-a5-[3-11],gpu-a5-1
SwitchName=b8cef60300dc3d6a Nodes=compute-a7-[1-20],compute-a8-[1-20]
SwitchName=b8cef60300d85ac0 Nodes=compute-a8-[21-60]
SwitchName=b8cef60300dc426a Nodes=compute-b7-[21-60]
SwitchName=b8cef60300d55b46 Nodes=gpu-b9-[1-7],gpu-b10-[1-7],gpu-b11-[1-6]
SwitchName=b8cef60300d55ba6 Nodes=compute-b5-[1-20],compute-b6-[1-20]
SwitchName=b8cef60300dc3f4a Nodes=compute-a7-[21-60]
SwitchName=b8cef60300d85800 Nodes=compute-b5-[21-60]
SwitchName=b8cef60300d85ae0 Nodes=compute-b6-[21-60]
SwitchName=b8cef60300dc43ea Nodes=bigmem-a9-[1-6]
SwitchName=b8cef60300d85b00 Nodes=compute-b8-[21-52,54-60]
SwitchName=b8cef60300d55b66 Nodes=compute-b7-[1-20],compute-b8-[1-20]
