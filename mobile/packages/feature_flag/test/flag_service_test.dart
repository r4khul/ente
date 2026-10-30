import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:ente_feature_flag/ente_feature_flag.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'uses the session reader and discards a response after logout',
    () async {
      SharedPreferences.setMockInitialValues({'user_id': 1});
      final preferences = await SharedPreferences.getInstance();
      String? token = 'secure-session';
      Completer<void>? requestStarted;
      late RequestInterceptorHandler pendingRequest;
      late RequestOptions requestOptions;
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requestOptions = options;
            if (requestStarted == null) {
              handler.resolve(
                Response(
                  requestOptions: options,
                  data: {'betaUser': true},
                  statusCode: 200,
                ),
              );
            } else {
              pendingRequest = handler;
              requestStarted.complete();
            }
          },
        ),
      );
      final service = FlagService(preferences, dio, getToken: () => token);
      await service.tryRefreshFlags();
      expect(
        jsonDecode(preferences.getString('remote_flags')!)['betaUser'],
        true,
      );

      requestStarted = Completer<void>();
      final refresh = service.tryRefreshFlags();
      await requestStarted.future;
      token = null;
      await preferences.clear();
      pendingRequest.resolve(
        Response(
          requestOptions: requestOptions,
          data: {'betaUser': true},
          statusCode: 200,
        ),
      );
      await refresh;
      expect(preferences.containsKey('remote_flags'), false);
    },
  );
}
