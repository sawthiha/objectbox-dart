import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flat_buffers/flat_buffers.dart' as fb;

import 'nativemem.dart';

// ignore_for_file: public_member_api_docs

// Note: touch this file with caution, it's a hotspot and optimized for our use.

class BuilderWithCBuffer {
  final _allocator = Allocator();
  final int _initialSize;
  final int _resetIfLargerThan;

  late fb.Builder _fbb;

  fb.Builder get fbb => _fbb;

  @pragma('vm:prefer-inline')
  Pointer<Void> get bufPtr => Pointer<Void>.fromAddress(
      _allocator.bufAddress + _allocator._capacity - _fbb.size());

  BuilderWithCBuffer({int initialSize = 256, int resetIfLargerThan = 64 * 1024})
      : _initialSize = initialSize,
        _resetIfLargerThan = resetIfLargerThan {
    _fbb = fb.Builder(
      initialSize: initialSize,
      allocator: _allocator,
      deduplicateTables: false, // we always have exactly one table
    );
  }

  @pragma('vm:prefer-inline')
  void resetIfLarge() {
    if (_allocator._capacity > _resetIfLargerThan) {
      clear();
      _fbb = fb.Builder(initialSize: _initialSize, allocator: _allocator);
    }
  }

  void clear() => _allocator.freeAll();

  Allocator get allocator => _allocator;
}

class Allocator extends fb.Allocator {
  Pointer<Uint8>? _ptr;

  // allocated buffer capacity
  int _capacity = 0;

  @pragma('vm:prefer-inline')
  int get bufAddress {
    assert(_ptr!.address != 0);
    return _ptr!.address;
  }

  ByteData get _view => ByteData.view(_ptr!.asTypedList(_capacity).buffer);

  @override
  ByteData allocate(int size) {
    _capacity = size;
    // FB Builder only calls allocate once
    assert(_ptr == null);
    _ptr = malloc<Uint8>(size);
    return _view;
  }

  @override
  void deallocate(ByteData data) {
    assert(false); // never called because [resize()] is overridden
  }

  @override
  ByteData resize(
      ByteData oldData, int newSize, int inUseBack, int inUseFront) {
    final newPtr = malloc<Uint8>(newSize);
    final oldPtr = _ptr!;
    if (inUseBack != 0) {
      memcpy(
          Pointer<Uint8>.fromAddress(newPtr.address + newSize - inUseBack),
          Pointer<Uint8>.fromAddress(oldPtr.address + _capacity - inUseBack),
          inUseBack);
    }
    if (inUseFront != 0) {
      memcpy(newPtr, oldPtr, inUseFront);
    }
    _capacity = newSize;
    _ptr = newPtr;
    malloc.free(oldPtr);
    return _view;
  }

  void freeAll() {
    if (_ptr != null) {
      malloc.free(_ptr!);
      _ptr = null;
    }
  }
}

/// Implements a native data access wrapper to circumvent Pointer.asTypedList()
/// slowness. The idea is to reuse the same buffer and rather memcpy the data,
/// which ends up being faster than calling asTypedList(). Hopefully, we will
/// be able to remove this if (when) asTypedList() gets optimized in Dart SDK.
class ReaderWithCBuffer {
  // See /benchmark/bin/native_pointers.dart for the max buffer size where it
  // still makes sense to use memcpy. On Linux, memcpy starts to be slower at
  // about 10-15 KiB. TODO test on other platforms to find an optimal limit.
  static const _maxBuffer = 4 * 1024;
  final _bufferPtr = malloc<Uint8>(_maxBuffer);
  late final ByteBuffer _buffer = _bufferPtr.asTypedList(_maxBuffer).buffer;

  ReaderWithCBuffer() {
    assert(_bufferPtr.asTypedList(_maxBuffer).offsetInBytes == 0);
  }

  void clear() => malloc.free(_bufferPtr);

  ByteData access(Pointer<Uint8> dataPtr, int size) {
    // If memcpy is not available, instead of using Dart memcpy implementation,
    // directly convert to view which is a little faster.
    if (isMemcpyNotAvailable || size > _maxBuffer) {
      final uint8List = dataPtr.asTypedList(size);
      return ByteData.view(uint8List.buffer, uint8List.offsetInBytes, size);
    } else {
      memcpy(_bufferPtr, dataPtr, size);
      return ByteData.view(_buffer, 0, size);
    }
  }
}
