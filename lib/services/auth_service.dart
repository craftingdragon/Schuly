import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../config/backend_config.dart';

/// Why a token refresh failed.
enum AuthFailure {
  /// The server rejected the refresh token - the session is over and the user
  /// has to sign in again.
  auth,

  /// The server couldn't be reached (no network, timeout, 5xx, a malformed
  /// response). The stored tokens are still good: retry, don't sign out.
  transport,
}

/// Outcome of [AuthService.refreshAccessToken]: either a fresh access token or
/// the reason it couldn't be minted.
class AuthRefresh {
  const AuthRefresh.token(String this.accessToken) : failure = null;
  const AuthRefresh.failed(AuthFailure this.failure) : accessToken = null;

  final String? accessToken;
  final AuthFailure? failure;
}

/// A single sign-on provider offered by the Schuly server.
class SignInProvider {
  const SignInProvider(this.key, this.displayName, this.iconUrl);

  final String key;
  final String displayName;
  final String? iconUrl;
}

/// A refusal from the server, worded for the user.
class AuthException implements Exception {
  const AuthException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// Federated authentication against the Schuly server. Session tokens live in
/// the platform keystore; refresh and logout stay on the same server session.
class AuthService {
  static const _kRefreshTokenKey = 'auth.refresh_token';
  static const _kAccessTokenKey = 'auth.access_token.v2';
  static const _kAccessTokenExpiryKey = 'auth.access_token_expiry';
  static const _kLegacyKeys = ['auth.access_token', 'auth.id_token'];

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static String? _accessToken;
  static DateTime? _accessTokenExpiry;

  static final ValueNotifier<int> sessionEpoch = ValueNotifier<int>(0);

  static Uri _uri(String path) => Uri.parse('${BackendConfig.url}$path');

  static Future<http.Response> _post(String path, Map<String, Object?> body) {
    return http.post(
      _uri(path),
      headers: {HttpHeaders.contentTypeHeader: 'application/json'},
      body: jsonEncode(body),
    ).timeout(const Duration(seconds: 20));
  }

  static AuthException _refusal(http.Response response, String fallback) {
    try {
      final body = jsonDecode(response.body);
      if (body is Map) {
        final errors = body['errors'];
        if (errors is List && errors.isNotEmpty) return AuthException(errors.join(' '), statusCode: response.statusCode);
        final description = body['error_description'];
        if (description is String && description.isNotEmpty) return AuthException(description, statusCode: response.statusCode);
      }
    } catch (_) {}
    if (response.statusCode == 429) return AuthException('Too many attempts. Wait a minute and try again.', statusCode: response.statusCode);
    return AuthException(fallback, statusCode: response.statusCode);
  }

  static const _externalErrors = {
    'access_denied': 'You cancelled the sign-in.',
    'account_not_found': 'This identity is not allowed to sign in to Schuly. Contact your administrator if you need access.',
    'account_exists': 'This identity could not be linked to a Schuly account. Contact your administrator.',
    'external_login_failed': 'Signing in with that provider did not work. Try again.',
  };

  static String get _callbackScheme => appFlavor == 'dev' ? 'schuly-dev' : 'schuly';

  /// The single sign-on providers the server offers; empty when it offers none.
  static Future<List<SignInProvider>> providers() async {
    try {
      final response = await http.get(_uri('/auth/providers')).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return const [];
      return [
        for (final entry in jsonDecode(response.body) as List)
          SignInProvider(entry['key'] as String, (entry['display_name'] as String?) ?? entry['key'] as String, BackendConfig.resolveUrl(entry['icon_url'] as String?)),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Signs in through a provider in the system browser and stores the session.
  static Future<void> signInWithProvider(String provider) async {
    final verifier = _randomToken();
    final state = _randomToken();
    final challenge = base64Url.encode(sha256.convert(utf8.encode(verifier)).bytes).replaceAll('=', '');
    final start = _uri('/auth/external/${Uri.encodeComponent(provider)}/start').replace(queryParameters: {
      'returnUrl': '$_callbackScheme://auth/callback',
      'codeChallenge': challenge,
      'codeChallengeMethod': 'S256',
      'state': state,
    });

    final String result;
    try {
      result = await FlutterWebAuth2.authenticate(url: start.toString(), callbackUrlScheme: _callbackScheme);
    } on PlatformException catch (e) {
      if (e.code == 'CANCELED') throw AuthException(_externalErrors['access_denied']!);
      rethrow;
    }

    final query = Uri.parse(result).queryParameters;
    final error = query['error'];
    if (error != null) throw AuthException(_externalErrors[error] ?? _externalErrors['external_login_failed']!);
    final code = query['code'];
    if (code == null || query['state'] != state) throw AuthException(_externalErrors['external_login_failed']!);

    final response = await _post('/auth/external/exchange', {'code': code, 'codeVerifier': verifier});
    if (response.statusCode != 200) throw _refusal(response, _externalErrors['external_login_failed']!);
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    if (!body.containsKey('access_token')) {
      if (body['two_factor_required'] == true || body['email_verification_required'] == true) {
        throw const AuthException('Use your GamepowerX verification to finish signing in, or contact your administrator.');
      }
      throw const AuthException('The identity provider did not complete sign-in. Contact your administrator.');
    }
    await _persist(body);
  }

  static String _randomToken() {
    final random = Random.secure();
    return base64Url.encode(List<int>.generate(32, (_) => random.nextInt(256))).replaceAll('=', '');
  }

  static Future<String> _persist(Map<String, dynamic> body) async {
    final accessToken = body['access_token'] as String;
    final expiresIn = (body['expires_in'] as num?)?.toInt() ?? 900;
    _accessToken = accessToken;
    _accessTokenExpiry = DateTime.now().add(Duration(seconds: expiresIn));
    await _storage.write(key: _kAccessTokenKey, value: accessToken);
    await _storage.write(key: _kAccessTokenExpiryKey, value: _accessTokenExpiry!.toIso8601String());
    final refreshToken = body['refresh_token'] as String?;
    if (refreshToken != null) await _storage.write(key: _kRefreshTokenKey, value: refreshToken);
    sessionEpoch.value++;
    return accessToken;
  }

  static Future<void>? _restore;
  static Future<void> _ensureRestored() => _restore ??= _restoreAccessToken();

  static Future<void> _restoreAccessToken() async {
    for (final key in _kLegacyKeys) {
      await _storage.delete(key: key);
    }
    final token = await _storage.read(key: _kAccessTokenKey);
    final expiry = DateTime.tryParse(await _storage.read(key: _kAccessTokenExpiryKey) ?? '');
    if (token != null && expiry != null && _accessToken == null) {
      _accessToken = token;
      _accessTokenExpiry = expiry;
    }
  }

  /// Returns a usable access token: the cached one if still valid, otherwise a
  /// freshly refreshed one. Null when there's no session.
  static Future<String?> getAccessToken() async {
    await _ensureRestored();
    final token = _accessToken;
    final expiry = _accessTokenExpiry;
    if (token != null && expiry != null && expiry.isAfter(DateTime.now().add(const Duration(seconds: 30)))) {
      return token;
    }
    return (await refreshAccessToken()).accessToken;
  }

  /// Whether a refresh token is stored - the app has a session it can re-mint an
  /// access token from, even while it can't reach the server.
  static Future<bool> hasSession() async => await _storage.read(key: _kRefreshTokenKey) != null;

  static Future<AuthRefresh>? _refreshing;

  static Future<AuthRefresh> refreshAccessToken() => _refreshing ??= _refresh().whenComplete(() => _refreshing = null);

  static Future<AuthRefresh> _refresh() async {
    final refreshToken = await _storage.read(key: _kRefreshTokenKey);
    if (refreshToken == null) return const AuthRefresh.failed(AuthFailure.auth);
    try {
      final response = await _post('/auth/refresh', {'refreshToken': refreshToken});
      if (response.statusCode == 400 || response.statusCode == 401) return const AuthRefresh.failed(AuthFailure.auth);
      if (response.statusCode != 200) return const AuthRefresh.failed(AuthFailure.transport);
      return AuthRefresh.token(await _persist(jsonDecode(response.body) as Map<String, dynamic>));
    } catch (_) {
      return const AuthRefresh.failed(AuthFailure.transport);
    }
  }

  static Future<bool>? _signingOut;

  /// Ends the session. Memoised, because N requests failing at once must sign
  /// out once. Returns true only for the call that actually ended a live session.
  static Future<bool> signOut() {
    final pending = _signingOut;
    if (pending != null) return pending.then((_) => false);
    return _signingOut = _signOut().whenComplete(() => _signingOut = null);
  }

  static Future<bool> _signOut() async {
    final refreshToken = await _storage.read(key: _kRefreshTokenKey);
    final hadSession = refreshToken != null || _accessToken != null;
    if (refreshToken != null) {
      try {
        await _post('/auth/logout', {'refreshToken': refreshToken});
      } catch (_) {}
    }
    _accessToken = null;
    _accessTokenExpiry = null;
    await _storage.delete(key: _kRefreshTokenKey);
    await _storage.delete(key: _kAccessTokenKey);
    await _storage.delete(key: _kAccessTokenExpiryKey);
    final prefs = await SharedPreferences.getInstance();
    for (final key in [..._kLegacyKeys, _kRefreshTokenKey]) {
      await prefs.remove(key);
    }
    _restore = null;
    sessionEpoch.value++;
    return hadSession;
  }

}
