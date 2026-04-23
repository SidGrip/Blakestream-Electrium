import ctypes
import os
import sys

_hash_func = None

try:
    from _blake256 import hash as _hash_func
except ImportError:
    pass

if _hash_func is None:
    lib_names = []
    if sys.platform == 'win32':
        lib_names = ['blake256.dll']
    elif sys.platform == 'darwin':
        lib_names = ['libblake256.dylib']
    else:
        lib_names = ['libblake256.so', 'libblake256.so.0']

    search_dirs = [
        os.path.dirname(__file__),
        getattr(sys, '_MEIPASS', None),
        os.path.dirname(sys.executable),
        '.',
    ]
    search_dirs = [d for d in search_dirs if d]

    for search_dir in search_dirs:
        for lib_name in lib_names:
            lib_path = os.path.join(search_dir, lib_name)
            if os.path.exists(lib_path):
                try:
                    _dll = ctypes.CDLL(lib_path)
                except OSError:
                    continue
                _dll.blake256_hash.argtypes = [ctypes.c_char_p, ctypes.c_uint, ctypes.c_char_p]
                _dll.blake256_hash.restype = None

                def _ctypes_hash(data):
                    out = ctypes.create_string_buffer(32)
                    _dll.blake256_hash(data, len(data), out)
                    return out.raw

                _hash_func = _ctypes_hash
                break
        if _hash_func is not None:
            break

if _hash_func is None:
    raise ImportError("Blake-256 backend not found")


def blake256_hash(data: bytes) -> bytes:
    return _hash_func(data)


def getPoWHash(data: bytes) -> bytes:
    return blake256_hash(data)
