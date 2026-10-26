import pathlib
import struct
import sys

png = pathlib.Path(sys.argv[1]).read_bytes()
entry = b'ic10' + struct.pack('>I', 8 + len(png)) + png
pathlib.Path(sys.argv[2]).write_bytes(b'icns' + struct.pack('>I', 8 + len(entry)) + entry)
