/*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#include <string.h>

#define CAML_NAME_SPACE
#include <caml/alloc.h>
#include <caml/callback.h>
#include <caml/fail.h>
#include <caml/intext.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>

#include <lz4.h>

CAMLprim value marshal_and_compress_stub(value data) {
  CAMLparam1(data);
  CAMLlocal2(result, compressed_data);

  // TODO - well todoish. If data is a string, we don't need to marshal it.
  // We can just compress it directly. That's what hh_shared.c does. But at
  // the moment saved state is not a string, so we don't really need this
  // optimization

  intnat serialized_size;
  char* marshaled_value;

  // caml_output_value_to_malloc will allocate marshaled_value. We must free it
  caml_output_value_to_malloc(
      data, Val_int(0) /*flags*/, &marshaled_value, &serialized_size);

  if (serialized_size < 0) {
    caml_failwith("Failed to marshal");
  }

  size_t uncompressed_size = (size_t)serialized_size;

  size_t max_compression_size = LZ4_compressBound(uncompressed_size);
  char* compressed_value = caml_stat_alloc(max_compression_size);
  size_t compressed_size = LZ4_compress_default(
      marshaled_value,
      compressed_value,
      uncompressed_size,
      max_compression_size);
  if (compressed_size == 0) {
    caml_failwith("LZ4 failed to compress");
  }
  compressed_data =
      caml_alloc_initialized_string(compressed_size, compressed_value);
  caml_stat_free(compressed_value);

  caml_stat_free(marshaled_value);

  result = caml_alloc_tuple(3);
  Store_field(result, 0, compressed_data);
  Store_field(result, 1, Val_int(compressed_size));
  Store_field(result, 2, Val_int(uncompressed_size));

  CAMLreturn(result);
}

CAMLprim value decompress_and_unmarshal_stub(value compressed) {
  CAMLparam1(compressed);
  CAMLlocal1(result);

  const char* compressed_data = String_val(Field(compressed, 0));
  size_t compressed_size = Long_val(Field(compressed, 1));
  size_t uncompressed_size = Long_val(Field(compressed, 2));

  char* marshaled_value = caml_stat_alloc(uncompressed_size);
  size_t actual_uncompressed_size = LZ4_decompress_safe(
      compressed_data, marshaled_value, compressed_size, uncompressed_size);

  if (actual_uncompressed_size != uncompressed_size) {
    caml_failwith("Failed to decompress");
  }

  result = caml_input_value_from_block(marshaled_value, uncompressed_size);

  caml_stat_free(marshaled_value);

  CAMLreturn(result);
}
