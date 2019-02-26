// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:expect/expect.dart';

main() {
  /*1:main*/ test(new Class());
}

@NoInline()
test(c) {
  c.field. /*2:test*/ method();
}

class Class {
  var field;
}