// Copyright (c) 2019, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analysis_server/lsp_protocol/protocol_generated.dart';
import 'package:analysis_server/lsp_protocol/protocol_special.dart';
import 'package:test/test.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

import 'integration_tests.dart';

main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(InitializationTest);
  });
}

@reflectiveTest
class InitializationTest extends AbstractLspAnalysisServerIntegrationTest {
  skip_test_initialize_invalidParams() async {
    // skipped due to flaky timeouts, #38629
    final params = {'processId': 'invalid'};
    final request = new RequestMessage(
      Either2<num, String>.t1(1),
      Method.initialize,
      params,
      jsonRpcVersion,
    );
    final response = await sendRequestToServer(request);
    expect(response.id, equals(request.id));
    expect(response.error, isNotNull);
    expect(response.error.code, equals(ErrorCodes.InvalidParams));
    expect(response.result, isNull);
  }
}
