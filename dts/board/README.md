# The board DTS the BPI-W2 runs

`rtd1296-bananapi-w2.dts` is a copy of the PiKVM repository's
`kernel/mainline/rtd1296-bananapi-w2.dts` (branch `kernel-6.18`, commit
`3398bdd`) **with the nodes from this repository appended**: the second
RJ45 (`dts/nat-eth.dtsi`), SATA (`dts/sata.dtsi`) and the IR receiver
(`dts/ir.dtsi`). In the PiKVM repository those additions are an
uncommitted change; this copy keeps them safe.
`rtd1296-bananapi-w2.dts.pikvm.diff` is that change against `3398bdd`.

Built from it (2026-10-05, the PiKVM kernel tree, `make dtbs`):
`rtd1296-bananapi-w2.dtb`, 15737 bytes, md5
`f9a5e9b3677130618dd96e4210f667ac` -- the DTB installed on the board
(`/boot/bananapi/bpi-w2/linux/bpi-w2.dtb` and the eMMC's raw slot), with
`bpi-w2.dtb.prev` = `6e491f5e0b18feec7cc07f09c2657954` (second RJ45
only) on the board for rollback (`scripts/install-dtb.sh --rollback`).

It includes `rtd1296.dtsi` and the dt-bindings headers of the kernel
tree, so it builds only inside a kernel tree (docs/device-tree.md).
