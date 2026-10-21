import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' show join;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:cryptography/cryptography.dart';

abstract final class AppPalette {
  static const primary = Color(0xFF6D72E9);
  static const primaryDark = Color(0xFF5963CE);
  static const secondary = Color(0xFFC77BEF);
  static const soft = Color(0xFFF0EEFF);
  static const background = Color(0xFFF5F6FF);
  static const text = Color(0xFF242432);
  static const muted = Color(0xFF7B7C8E);
  static const coral = Color(0xFFFF7B9C);
  static const mint = Color(0xFF59CDBB);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  await AppNotifications.initialize();
  runApp(const ForageApp());
}

abstract final class AppNotifications {
  static final _notifications = FlutterLocalNotificationsPlugin();

  static Future<void> initialize() async {
    try {
      const settings = InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      );
      await _notifications.initialize(settings);
      await _notifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
    } catch (_) {
      // Notifications are optional on desktop platforms and must never block
      // the workshop from opening.
    }
  }

  static Future<void> show({
    required String title,
    required String body,
  }) async {
    try {
      const details = NotificationDetails(
        android: AndroidNotificationDetails(
          'workshop_events',
          'Événements de l’atelier',
          channelDescription: 'Alertes de stock, opérations et contrôles',
          importance: Importance.high,
          priority: Priority.high,
        ),
      );
      await _notifications.show(
        DateTime.now().microsecondsSinceEpoch.remainder(1 << 31),
        title,
        body,
        details,
      );
    } catch (_) {
      // A missing platform capability should not interrupt the business flow.
    }
  }
}

enum UserRole { admin, operator, visitor, validation }

/// Pages are granted independently from roles. Roles remain useful shortcuts,
/// while this list lets an administrator give a person only the screens needed.
enum AppPage { dashboard, products, stock, machines, team, validation, analytics }

extension AppPageLabel on AppPage {
  String get label => switch (this) {
    AppPage.dashboard => 'Accueil',
    AppPage.products => 'Produits',
    AppPage.stock => 'Stock',
    AppPage.machines => 'Machines',
    AppPage.team => 'Équipe',
    AppPage.validation => 'Validations',
    AppPage.analytics => 'Analyses',
  };
}

enum UserStatus { active, onLeave, dismissed }

enum LoginFailure { invalidCredentials, temporarilyLocked, inactiveAccount }

class LoginResult {
  const LoginResult.success(this.user) : failure = null;
  const LoginResult.failure(this.failure) : user = null;
  final AppUser? user;
  final LoginFailure? failure;
  bool get succeeded => user != null;
}

extension UserStatusLabel on UserStatus {
  String get label => switch (this) {
    UserStatus.active => 'Actif',
    UserStatus.onLeave => 'En congé',
    UserStatus.dismissed => 'Licencié définitivement',
  };
}

extension UserRoleLabel on UserRole {
  String get label => switch (this) {
    UserRole.admin => 'Administrateur',
    UserRole.operator => 'Opérateur',
    UserRole.visitor => 'Visiteur',
    UserRole.validation => 'Validation',
  };
}

class AppUser {
  AppUser({
    required this.id,
    required this.username,
    required this.password,
    required this.fullName,
    this.admin = false,
    this.role = UserRole.operator,
    Set<UserRole>? roles,
    Set<AppPage>? allowedPages,
    Set<AppPage>? writablePages,
    this.status = UserStatus.active,
    this.leaveUntil,
    this.isPrivateOwner = false,
  })  : roles = roles ?? {if (admin) UserRole.admin else role},
        allowedPages = allowedPages ?? _defaultPages(roles ?? {if (admin) UserRole.admin else role}),
        writablePages = writablePages ?? _defaultWritablePages(roles ?? {if (admin) UserRole.admin else role});
  final String id;
  final String username;
  final String password;
  final String fullName;
  final bool admin;
  /// Kept for compatibility with old backups. New records use [roles].
  final UserRole role;
  final Set<UserRole> roles;
  final Set<AppPage> allowedPages;
  final Set<AppPage> writablePages;
  final UserStatus status;
  final DateTime? leaveUntil;
  /// The private owner account is intentionally excluded from the team list.
  /// It is the only account allowed to open the destructive maintenance area.
  final bool isPrivateOwner;

  static Set<AppPage> _defaultPages(Set<UserRole> values) {
    if (values.contains(UserRole.admin)) return AppPage.values.toSet();
    final pages = <AppPage>{AppPage.dashboard};
    if (values.contains(UserRole.operator)) pages.add(AppPage.machines);
    if (values.contains(UserRole.validation)) pages.add(AppPage.validation);
    if (values.contains(UserRole.visitor)) {
      pages.addAll({AppPage.dashboard, AppPage.products, AppPage.stock, AppPage.machines, AppPage.team});
    }
    return pages;
  }

  static Set<AppPage> _defaultWritablePages(Set<UserRole> values) {
    if (values.contains(UserRole.admin)) return AppPage.values.toSet();
    if (values.contains(UserRole.operator)) return {AppPage.machines};
    if (values.contains(UserRole.validation)) return {AppPage.validation};
    return {};
  }

  bool get isAdmin => admin || roles.contains(UserRole.admin);
  UserRole get effectiveRole => isAdmin ? UserRole.admin : roles.first;
  bool get isOperator => roles.contains(UserRole.operator);
  bool get isVisitor => roles.contains(UserRole.visitor);
  bool get canValidate => isAdmin || roles.contains(UserRole.validation);
  bool get isDeveloper => isPrivateOwner && isAdmin;
  /// Leave and dismissal block access until an administrator explicitly
  /// reactivates the account. A leave end date is informational only.
  bool get canLogIn => status == UserStatus.active;
  bool canAccess(AppPage page) => isAdmin || allowedPages.contains(page);
  bool canWritePage(AppPage page) => isAdmin || writablePages.contains(page);

  AppUser copyWith({
    String? password,
    Set<UserRole>? roles,
    Set<AppPage>? allowedPages,
    Set<AppPage>? writablePages,
    UserStatus? status,
    DateTime? leaveUntil,
    bool clearLeaveUntil = false,
    bool? isPrivateOwner,
  }) => AppUser(
    id: id, username: username, password: password ?? this.password, fullName: fullName,
    admin: (roles ?? this.roles).contains(UserRole.admin),
    role: (roles ?? this.roles).first,
    roles: roles ?? this.roles,
    allowedPages: allowedPages ?? this.allowedPages,
    writablePages: writablePages ?? this.writablePages,
    status: status ?? this.status,
    leaveUntil: clearLeaveUntil ? null : (leaveUntil ?? this.leaveUntil),
    isPrivateOwner: isPrivateOwner ?? this.isPrivateOwner,
  );
}

class UserSession {
  const UserSession({required this.id, required this.userId, required this.loggedInAt, this.loggedOutAt});
  final String id;
  final String userId;
  final DateTime loggedInAt;
  final DateTime? loggedOutAt;
}

/// Encryption helpers used only for backup files.
abstract final class PasswordSecurity {
  static const _iterations = 310000;
  static final _algorithm = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: _iterations,
    bits: 256,
  );

  static Future<Map<String, String>> encryptBackup(
    Uint8List plaintext,
    String passphrase,
  ) async {
    final salt = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    final nonce = List<int>.generate(12, (_) => Random.secure().nextInt(256));
    final key = await _algorithm.deriveKey(
      secretKey: SecretKey(utf8.encode(passphrase)),
      nonce: salt,
    );
    final box = await AesGcm.with256bits().encrypt(
      plaintext,
      secretKey: key,
      nonce: nonce,
    );
    return {
      'salt': base64UrlEncode(salt),
      'nonce': base64UrlEncode(nonce),
      'ciphertext': base64UrlEncode(box.cipherText),
      'mac': base64UrlEncode(box.mac.bytes),
    };
  }

  static Future<Uint8List> decryptBackup(
    Map<dynamic, dynamic> envelope,
    String passphrase,
  ) async {
    try {
      final salt = base64Url.decode(envelope['salt'] as String);
      final key = await _algorithm.deriveKey(
        secretKey: SecretKey(utf8.encode(passphrase)),
        nonce: salt,
      );
      final box = SecretBox(
        base64Url.decode(envelope['ciphertext'] as String),
        nonce: base64Url.decode(envelope['nonce'] as String),
        mac: Mac(base64Url.decode(envelope['mac'] as String)),
      );
      return Uint8List.fromList(
        await AesGcm.with256bits().decrypt(box, secretKey: key),
      );
    } catch (_) {
      throw const FormatException('Mot de passe incorrect ou sauvegarde altérée.');
    }
  }
}

/// Passwords are stored as a slow, salted one-way derivation.  This is kept
/// separate from backup encryption: a password verifier must never be usable
/// to recover the original password.
abstract final class CredentialSecurity {
  static const _prefix = r'$pbkdf2-sha256$v1$';
  static const _iterations = 600000;

  static bool isHash(String value) => value.startsWith(_prefix);

  /// Native builds run this deliberately expensive operation off the UI
  /// isolate, so a secure login never freezes the form.
  static Future<String> hash(String password) =>
      compute(_hashCredentialPassword, password, debugLabel: 'Password hashing');

  static Future<bool> verify(String password, String encoded) => compute(
        _verifyCredentialPassword,
        {'password': password, 'encoded': encoded},
        debugLabel: 'Password verification',
      );

  static bool _constantTimeEquals(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    var difference = 0;
    for (var index = 0; index < left.length; index++) {
      difference |= left[index] ^ right[index];
    }
    return difference == 0;
  }
}

Future<String> _hashCredentialPassword(String password) async {
  final salt = List<int>.generate(16, (_) => Random.secure().nextInt(256));
  final algorithm = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: CredentialSecurity._iterations,
    bits: 256,
  );
  final key = await algorithm.deriveKey(
    secretKey: SecretKey(utf8.encode(password)),
    nonce: salt,
  );
  final bytes = await key.extractBytes();
  return '${CredentialSecurity._prefix}${base64UrlEncode(salt)}\$${base64UrlEncode(bytes)}';
}

Future<bool> _verifyCredentialPassword(Map<String, String> input) async {
  final encoded = input['encoded'];
  final password = input['password'];
  if (encoded == null || password == null || !CredentialSecurity.isHash(encoded)) {
    return false;
  }
  final parts = encoded.substring(CredentialSecurity._prefix.length).split(r'$');
  if (parts.length != 2) return false;
  try {
    final salt = base64Url.decode(parts[0]);
    final expected = base64Url.decode(parts[1]);
    if (salt.length != 16 || expected.length != 32) return false;
    final algorithm = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: CredentialSecurity._iterations,
      bits: 256,
    );
    final key = await algorithm.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: salt,
    );
    return CredentialSecurity._constantTimeEquals(
      await key.extractBytes(),
      expected,
    );
  } catch (_) {
    return false;
  }
}

class Product {
  const Product({
    required this.id,
    required this.name,
    required this.width,
    required this.lengthMeters,
    required this.lengthUnit,
    required this.thickness,
    required this.kind,
    required this.initialStock,
    required this.initialDepotId,
    required this.material,
    this.hoseUnit = HoseUnit.piece,
    this.metersPerPiece,
    this.diameter,
    this.reference = '',
    this.image,
    this.parentProductId,
  });
  final String id;
  final String name;

  /// Width is stored in metres and thickness in millimetres.
  final double width;

  /// The canonical value used in all calculations.
  final double lengthMeters;
  final LengthUnit lengthUnit;
  final double thickness;
  final ProductKind kind;

  /// Quantity available when the product is first created.
  final int initialStock;
  final String initialDepotId;
  final MaterialType material;
  final HoseUnit hoseUnit;

  /// Used only for pipes managed by piece: their length in metres.
  final double? metersPerPiece;
  /// Manually entered diameter in millimetres for diameter-based items.
  final double? diameter;
  final String reference;
  final Uint8List? image;

  /// A manufactured variant points to its dimensionless production template.
  /// Templates have no parent; each produced size gets its own product row.
  final String? parentProductId;

  double get lengthInChosenUnit => lengthMeters / lengthUnit.metres;
  bool get manufactured => kind == ProductKind.manufactured;
  bool get isManufacturedTemplate => manufactured && parentProductId == null;
  bool get isManufacturedVariant => manufactured && parentProductId != null;
  bool get isHose => kind == ProductKind.hose;
  bool get hoseManagedByMeter => isHose && hoseUnit == HoseUnit.meter;
  bool get isDiameterBased => kind == ProductKind.diameter;
  bool get canBeUsedInMachine => kind == ProductKind.standard;
  /// Standard products derive their diameter from the entered length using
  /// D = L / 3.14, preserving the length unit selected by the user.
  double? get displayedDiameter => isDiameterBased
      ? diameter
      : kind == ProductKind.standard
      ? lengthInChosenUnit / 3.14
      : null;
  String get displayedDiameterUnit => isDiameterBased ? 'mm' : lengthUnit.label;
  double get kilogramsPerPiece => kilogramsForDimensions(
    widthMeters: width,
    lengthMeters: lengthMeters,
    thicknessMillimetres: thickness,
    densityKilogramsPerCubicMeter: material.density,
  );
}

/// Result returned by the product form. Categories retain their product lists,
/// so the selected category is saved alongside a new raw product.
class ProductCreation {
  const ProductCreation({required this.product, this.categoryId});

  final Product product;
  final String? categoryId;
}

class Depot {
  const Depot({required this.id, required this.name, this.image});
  final String id;
  final String name;
  final Uint8List? image;
}

enum MaterialType { steel, pvc }

enum HoseUnit { piece, meter }

extension HoseUnitLabel on HoseUnit {
  String get label => switch (this) {
    HoseUnit.piece => 'Par pièce',
    HoseUnit.meter => 'Par mètre',
  };
}

enum ProductKind { standard, hose, manufactured, diameter }

extension ProductKindLabel on ProductKind {
  String get label => switch (this) {
    ProductKind.standard => 'Produit standard',
    ProductKind.hose => 'Tuyau',
    ProductKind.manufactured => 'Produit fabriqué en usine',
    ProductKind.diameter => 'Foret / produit par diamètre',
  };

  String get description => switch (this) {
    ProductKind.standard => 'Produit avec les mesures habituelles, achetable et vendable.',
    ProductKind.hose => 'Géré par pièce ou par mètre. Il ne passe pas par une machine.',
    ProductKind.manufactured => 'Produit fabriqué dans l’entreprise à partir d’une machine.',
    ProductKind.diameter => 'Produit identifié par son diamètre, comme un foret. Il ne passe pas par une machine.',
  };
}

enum InventoryUnit { piece, meter, centimeter, kilogram }

extension InventoryUnitLabel on InventoryUnit {
  String get label => switch (this) {
    InventoryUnit.piece => 'Pièce',
    InventoryUnit.meter => 'Mètre',
    InventoryUnit.centimeter => 'Centimètre',
    InventoryUnit.kilogram => 'Kilogramme',
  };

  String get shortLabel => switch (this) {
    InventoryUnit.piece => 'pièce(s)',
    InventoryUnit.meter => 'm',
    InventoryUnit.centimeter => 'cm',
    InventoryUnit.kilogram => 'kg',
  };
}

String formatQuantity(double value, InventoryUnit unit) =>
    '${formatNumber(value)} ${unit.shortLabel}';

int piecesForQuantity(Product product, double quantity, InventoryUnit unit) {
  final perPiece = switch (unit) {
    InventoryUnit.piece => 1.0,
    InventoryUnit.meter => product.lengthMeters,
    InventoryUnit.centimeter => product.lengthMeters * 100,
    InventoryUnit.kilogram => product.kilogramsPerPiece,
  };
  if (quantity <= 0 || perPiece <= 0) return 0;
  return (quantity / perPiece).ceil();
}

class Supplier {
  const Supplier({
    required this.id,
    required this.name,
    required this.company,
    required this.contact,
    required this.images,
  });
  final String id;
  final String name;
  final String company;
  final String contact;
  final List<Uint8List> images;
}

class Client {
  const Client({
    required this.id,
    required this.name,
    required this.company,
    required this.phone,
    required this.ice,
    required this.images,
  });
  final String id;
  final String name;
  final String company;
  final String phone;
  final String ice;
  final List<Uint8List> images;
}

class Sale {
  const Sale({
    required this.id,
    required this.productId,
    required this.depotId,
    required this.clientId,
    required this.pieces,
    required this.quantity,
    required this.unit,
    required this.images,
    required this.createdAt,
    this.draft = true,
  });
  final String id;
  final String productId;
  final String depotId;
  final String clientId;
  final int pieces;
  final double quantity;
  final InventoryUnit unit;
  final List<Uint8List> images;
  final DateTime createdAt;
  final bool draft;
}

/// A depot-to-depot movement has no effect on stock until it is approved.
class StockTransfer {
  const StockTransfer({
    required this.id,
    required this.productId,
    required this.sourceDepotId,
    required this.destinationDepotId,
    required this.pieces,
    required this.createdAt,
    this.draft = true,
  });
  final String id;
  final String productId;
  final String sourceDepotId;
  final String destinationDepotId;
  final int pieces;
  final DateTime createdAt;
  final bool draft;
}

/// A return is kept separately from its sale so the original invoice remains
/// auditable; it becomes available in its depot only once approved.
class SaleReturn {
  const SaleReturn({
    required this.id,
    required this.saleId,
    required this.productId,
    required this.depotId,
    required this.pieces,
    required this.createdAt,
    this.status = ReturnValidationStatus.pending,
  });
  final String id;
  final String saleId;
  final String productId;
  final String depotId;
  final int pieces;
  final DateTime createdAt;
  final ReturnValidationStatus status;
}

/// A return changes stock only after it is accepted by a validator.
enum ReturnValidationStatus { pending, approved, rejected }

extension ReturnValidationStatusLabel on ReturnValidationStatus {
  String get label => switch (this) {
    ReturnValidationStatus.pending => 'En attente de validation',
    ReturnValidationStatus.approved => 'Validé',
    ReturnValidationStatus.rejected => 'Refusé',
  };
}

extension MaterialTypeLabel on MaterialType {
  String get label => this == MaterialType.steel ? 'Fer / acier' : 'PVC';
  double get density => this == MaterialType.steel ? 7850 : 1400;
  String get formulaLabel =>
      'largeur × longueur × épaisseur × ${density.toStringAsFixed(0)} kg/m³';
}

class ProductCategory {
  const ProductCategory({
    required this.id,
    required this.name,
    required this.productIds,
    required this.image,
  });
  final String id;
  final String name;
  final List<String> productIds;
  final Uint8List image;
}

abstract final class PdfReports {
  static const _brand = 'FORAGE ZOUHOUR';

  static Future<void> printAllProducts({
    required List<Product> products,
    required List<Depot> depots,
    required int Function(String productId, String depotId) depotStock,
  }) async {
    final document = pw.Document();
    final rows = products.map((product) {
      final total = depots.fold<int>(
        0,
        (sum, depot) => sum + depotStock(product.id, depot.id),
      );
      final stockByDepot = depots
          .map((depot) => MapEntry(depot.name, depotStock(product.id, depot.id)))
          .where((entry) => entry.value != 0)
          .map((entry) => '${entry.key}: ${productQuantityLabel(product, entry.value)}')
          .join('\n');
      return [
        product.name,
        productQuantityLabel(product, product.initialStock),
        productQuantityLabel(product, total),
        stockByDepot.isEmpty ? '—' : stockByDepot,
      ];
    }).toList();
    document.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(28),
        header: (_) => pw.Text(
          '$_brand - Liste des produits',
          style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold),
        ),
        footer: (context) => pw.Align(
          alignment: pw.Alignment.centerRight,
          child: pw.Text('Page ${context.pageNumber} / ${context.pagesCount}'),
        ),
        build: (_) => [
          pw.SizedBox(height: 6),
          pw.Text(
            'État des stocks imprimé le ${_dateLabel(DateTime.now())}',
            style: const pw.TextStyle(color: PdfColors.grey700),
          ),
          pw.SizedBox(height: 16),
          pw.TableHelper.fromTextArray(
            headers: const [
              'Produit',
              'Stock initial',
              'Stock actuel',
              'Dépôts non vides',
            ],
            data: rows,
            headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, color: PdfColors.white),
            headerDecoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFF3D2BC7)),
            columnWidths: const {
              0: pw.FlexColumnWidth(2),
              1: pw.FlexColumnWidth(1),
              2: pw.FlexColumnWidth(1),
              3: pw.FlexColumnWidth(3),
            },
            cellAlignment: pw.Alignment.centerLeft,
            cellPadding: const pw.EdgeInsets.all(7),
          ),
        ],
      ),
    );
    await Printing.layoutPdf(onLayout: (_) => document.save());
  }

  static Future<void> printProductDetails({
    required Product product,
    required List<ProductCategory> categories,
    required List<Depot> depots,
    required int Function(String productId, String depotId) depotStock,
  }) async {
    final document = pw.Document();
    final categoryNames = categories
        .where((category) => category.productIds.contains(product.id))
        .map((category) => category.name)
        .join(', ');
    final total = depots.fold<int>(
      0,
      (sum, depot) => sum + depotStock(product.id, depot.id),
    );
    final details = [
      ['Nom', product.name],
      if (product.reference.isNotEmpty) ['Référence', product.reference],
      ['Type', product.kind.label],
      ['Catégorie', categoryNames.isEmpty ? 'Aucune' : categoryNames],
      if (product.isDiameterBased)
        ['Diamètre', 'Ø ${formatNumber(product.displayedDiameter ?? 0)} ${product.displayedDiameterUnit}']
      else if (product.isHose)
        ['Unité de vente', 'Mètre']
      else ...[
        ['Matière', '${product.material.label} - ${formatNumber(product.material.density)} kg/m³'],
        ['Longueur', '${formatNumber(product.lengthInChosenUnit)} ${product.lengthUnit.label} (${formatNumber(product.lengthMeters)} m)'],
        if (product.displayedDiameter != null)
          ['Diamètre calculé', 'Ø ${formatNumber(product.displayedDiameter!)} ${product.displayedDiameterUnit}'],
        ['Largeur', '${formatNumber(product.width)} m'],
        ['Épaisseur', '${formatNumber(product.thickness)} mm'],
        ['Poids estimé par pièce', formatWeight(product.kilogramsPerPiece)],
      ],
      ['Stock total', productQuantityLabel(product, total)],
      if (!product.isDiameterBased)
        ['Longueur totale en stock', '${formatNumber(total * product.lengthMeters)} m'],
      if (!product.isHose && !product.isDiameterBased)
        ['Poids total en stock', formatWeight(total * product.kilogramsPerPiece)],
    ];
    final stockRows = depots
        .map((depot) => [depot.name, productQuantityLabel(product, depotStock(product.id, depot.id))])
        .where((row) => row[1] != productQuantityLabel(product, 0))
        .toList();
    document.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(28),
        header: (_) => pw.Text(
          '$_brand - Fiche produit',
          style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold),
        ),
        build: (_) => [
          pw.Text(product.name, style: pw.TextStyle(fontSize: 24, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 14),
          pw.TableHelper.fromTextArray(
            headers: const ['Information', 'Valeur'],
            data: details,
            headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, color: PdfColors.white),
            headerDecoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFF3D2BC7)),
            cellPadding: const pw.EdgeInsets.all(7),
          ),
          pw.SizedBox(height: 20),
          pw.Text('Répartition par dépôt', style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 8),
          if (stockRows.isEmpty)
            pw.Text('Aucun dépôt ne contient actuellement ce produit.')
          else
            pw.TableHelper.fromTextArray(
              headers: const ['Dépôt', 'Quantité'],
              data: stockRows,
              headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, color: PdfColors.white),
              headerDecoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFF3D2BC7)),
              cellPadding: const pw.EdgeInsets.all(7),
            ),
        ],
        footer: (context) => pw.Align(
          alignment: pw.Alignment.centerRight,
          child: pw.Text('$_brand · Page ${context.pageNumber} / ${context.pagesCount}'),
        ),
      ),
    );
    await Printing.layoutPdf(onLayout: (_) => document.save());
  }

  static String _dateLabel(DateTime value) =>
      '${value.day.toString().padLeft(2, '0')}/${value.month.toString().padLeft(2, '0')}/${value.year}';
}

enum LengthUnit { meter, kilometer, centimeter, millimeter }

extension LengthUnitLabel on LengthUnit {
  String get label => switch (this) {
    LengthUnit.meter => 'm',
    LengthUnit.kilometer => 'km',
    LengthUnit.centimeter => 'cm',
    LengthUnit.millimeter => 'mm',
  };

  double get metres => switch (this) {
    LengthUnit.meter => 1,
    LengthUnit.kilometer => 1000,
    LengthUnit.centimeter => .01,
    LengthUnit.millimeter => .001,
  };
}

/// Thickness is stored in millimetres, but the form may receive centimetres
/// or metres. Keeping this conversion separate from [LengthUnit] avoids
/// accidentally treating a thickness as a length in metres.
enum ThicknessUnit { millimeter, centimeter, meter }

extension ThicknessUnitLabel on ThicknessUnit {
  String get label => switch (this) {
    ThicknessUnit.millimeter => 'mm',
    ThicknessUnit.centimeter => 'cm',
    ThicknessUnit.meter => 'm',
  };

  double get millimetres => switch (this) {
    ThicknessUnit.millimeter => 1,
    ThicknessUnit.centimeter => 10,
    ThicknessUnit.meter => 1000,
  };
}

/// Dimensions are normalised to metres and millimetres before calculating a
/// mass. The resulting value is always kilograms.
double kilogramsForDimensions({
  required double widthMeters,
  required double lengthMeters,
  required double thicknessMillimetres,
  required double densityKilogramsPerCubicMeter,
}) =>
    widthMeters *
    lengthMeters *
    (thicknessMillimetres / 1000) *
    densityKilogramsPerCubicMeter;

enum MachineType { standard, roulage }

class FactoryMachine {
  const FactoryMachine({
    required this.id,
    required this.name,
    required this.type,
    required this.categoryId,
    required this.outputId,
    required this.units,
    required this.operatorIds,
    this.image,
    this.temporary = false,
    this.deadline,
    this.plannedPieces,
    this.hopperPieces,
    this.temporaryInputProductId,
    this.temporarySourceDepotId,
    this.temporaryInputPieces,
  });
  final String id;
  final String name;
  final MachineType type;
  final String categoryId;
  final String outputId;
  final List<MachineUnit> units;
  final List<String> operatorIds;
  /// Old installations have one machine picture. New machines store the
  /// picture on every [MachineUnit], while this stays as a safe fallback.
  final Uint8List? image;
  final bool temporary;
  final DateTime? deadline;
  final int? plannedPieces;
  /// Number of sheets in one hopper for a temporary rolling job.
  final int? hopperPieces;
  /// Material sent to an external temporary workshop.
  final String? temporaryInputProductId;
  final String? temporarySourceDepotId;
  final int? temporaryInputPieces;
  int get copies => units.length;
  int get usableCopies => units.where((unit) => unit.usable).length;
}

enum MachineUnitState { ready, temporarilyUnavailable, retired }

class MachineUnit {
  const MachineUnit({
    required this.number,
    this.image,
    this.state = MachineUnitState.ready,
    this.unavailableUntil,
  });
  final int number;
  final Uint8List? image;
  final MachineUnitState state;
  final DateTime? unavailableUntil;
  bool get usable =>
      state == MachineUnitState.ready ||
      (state == MachineUnitState.temporarilyUnavailable &&
          unavailableUntil != null &&
          unavailableUntil!.isBefore(DateTime.now()));
}

class Operation {
  static const hopperSheetLengthMeters = 1.5;

  Operation({
    required this.id,
    required this.machineId,
    required this.operatorId,
    required this.pieces,
    required this.productId,
    required this.sourceDepotId,
    required this.machineUnitNumber,
    required this.startedAt,
    this.hopperPieces,
    this.finishedAt,
    this.outputPieces,
    this.finalImage,
    this.remainderImage,
    this.scrapImage,
    this.outputDepotId,
    this.remainderDepotId,
    this.scrapDepotId,
    this.scrapProductId,
    this.remainderPieces = 0,
    this.needsReview = false,
    this.scrapPieces = 0,
    this.completionDraft = false,
    this.validatedAt,
    this.outputProductId,
    this.externalProduction = false,
  });
  final String id;
  final String machineId;
  final String operatorId;
  final int pieces;
  final String productId;
  final String sourceDepotId;
  final int machineUnitNumber;
  final int? hopperPieces;
  final DateTime startedAt;
  DateTime? finishedAt;
  int? outputPieces;
  Uint8List? finalImage;
  Uint8List? remainderImage;
  Uint8List? scrapImage;
  String? outputDepotId;
  String? remainderDepotId;
  String? scrapDepotId;
  String? scrapProductId;
  int remainderPieces;
  bool needsReview;
  int scrapPieces;
  bool completionDraft;
  DateTime? validatedAt;
  String? outputProductId;
  /// Work entrusted to an external workshop. It reaches stock only after
  /// validation and never belongs to an operator's payroll.
  final bool externalProduction;
  bool get active => finishedAt == null;
  double? get hopperLengthMeters =>
      hopperPieces == null ? null : hopperPieces! * hopperSheetLengthMeters;
}

class OperatorPayment {
  const OperatorPayment({
    required this.id,
    required this.operatorId,
    required this.amount,
    required this.paidAt,
  });
  final String id;
  final String operatorId;
  final double amount;
  final DateTime paidAt;
}

class WorkshopData {
  const WorkshopData({
    required this.products,
    required this.depots,
    required this.categories,
    required this.machines,
    required this.operations,
    required this.stockAdditions,
    required this.suppliers,
    required this.clients,
    required this.sales,
    required this.stockTransfers,
    required this.saleReturns,
    required this.payments,
    required this.received,
  });

  final List<Product> products;
  final List<Depot> depots;
  final List<ProductCategory> categories;
  final List<FactoryMachine> machines;
  final List<Operation> operations;
  final List<StockAddition> stockAdditions;
  final List<Supplier> suppliers;
  final List<Client> clients;
  final List<Sale> sales;
  final List<StockTransfer> stockTransfers;
  final List<SaleReturn> saleReturns;
  final List<OperatorPayment> payments;
  final Map<String, int> received;
}

class AppDatabase {
  AppDatabase({this._databasePath});

  static const _databaseName = 'forage.db';
  static const _generalDepotId = 'general-depot';
  static const _backupFormat = 'forage-zouhour-backup';
  static const _encryptedBackupFormat = 'forage-zouhour-encrypted-backup';
  static const _backupVersion = 3;
  static const _maximumFailedLogins = 5;
  static const _lockoutDuration = Duration(minutes: 15);
  static const _backupTables = [
    'products',
    'categories',
    'machines',
    'operations',
    'stock_additions',
    'suppliers',
    'clients',
    'sales',
    'stock_transfers',
    'sale_returns',
    'operator_payments',
    'depots',
  ];
  static const _binaryBackupColumns = {
    'products': {'image'},
    'categories': {'image'},
    'machines': {'image'},
    'operations': {'final_image', 'remainder_image'},
    'depots': {'image'},
  };
  final String? _databasePath;
  late final Future<Database> _database = _open();

  Future<Database> _open() async {
    final database = await openDatabase(
      _databasePath ?? join(await getDatabasesPath(), _databaseName),
      version: 31,
      onCreate: (database, version) async {
        await database.execute(
          "CREATE TABLE users (id TEXT PRIMARY KEY, username TEXT NOT NULL UNIQUE, password TEXT NOT NULL, full_name TEXT NOT NULL, admin INTEGER NOT NULL, role TEXT NOT NULL DEFAULT 'operator', roles TEXT NOT NULL DEFAULT '[\"operator\"]', allowed_pages TEXT NOT NULL DEFAULT '[]', writable_pages TEXT NOT NULL DEFAULT '[]', status TEXT NOT NULL DEFAULT 'active', leave_until INTEGER, failed_attempts INTEGER NOT NULL DEFAULT 0, locked_until INTEGER, is_private_owner INTEGER NOT NULL DEFAULT 0)",
        );
        await database.execute(
          'CREATE TABLE user_sessions (id TEXT PRIMARY KEY, user_id TEXT NOT NULL, logged_in_at INTEGER NOT NULL, logged_out_at INTEGER)',
        );
        await database.execute(
          'CREATE TABLE products (id TEXT PRIMARY KEY, name TEXT NOT NULL, reference TEXT NOT NULL DEFAULT \'\', width REAL NOT NULL, length_meters REAL NOT NULL, length_unit TEXT NOT NULL, thickness REAL NOT NULL, manufactured INTEGER NOT NULL, kind TEXT NOT NULL DEFAULT \'standard\', diameter REAL, hose_unit TEXT NOT NULL DEFAULT \'piece\', meters_per_piece REAL, initial_stock INTEGER NOT NULL, initial_depot_id TEXT NOT NULL DEFAULT \'general-depot\', material_type TEXT NOT NULL DEFAULT \'steel\', image BLOB, parent_product_id TEXT)',
        );
        await database.execute(
          'CREATE TABLE categories (id TEXT PRIMARY KEY, name TEXT NOT NULL, product_ids TEXT NOT NULL, image BLOB NOT NULL)',
        );
        await database.execute(
          'CREATE TABLE machines (id TEXT PRIMARY KEY, name TEXT NOT NULL, copies INTEGER NOT NULL, type TEXT NOT NULL, inputs TEXT NOT NULL, output TEXT NOT NULL, operator_ids TEXT NOT NULL, image BLOB, category_id TEXT, units TEXT NOT NULL DEFAULT \'[]\', temporary INTEGER NOT NULL DEFAULT 0, deadline INTEGER, planned_pieces INTEGER, hopper_pieces INTEGER, temporary_input_product_id TEXT, temporary_source_depot_id TEXT, temporary_input_pieces INTEGER)',
        );
        await database.execute(
          'CREATE TABLE operations (id TEXT PRIMARY KEY, machine_id TEXT NOT NULL, operator_id TEXT NOT NULL, pieces INTEGER NOT NULL, hopper_pieces INTEGER, started_at INTEGER NOT NULL, finished_at INTEGER, output_pieces INTEGER, final_image BLOB, product_id TEXT NOT NULL, source_depot_id TEXT NOT NULL DEFAULT \'general-depot\', output_depot_id TEXT, remainder_depot_id TEXT, machine_unit_number INTEGER NOT NULL, remainder_image BLOB, needs_review INTEGER NOT NULL DEFAULT 0, scrap_pieces INTEGER NOT NULL DEFAULT 0, completion_draft INTEGER NOT NULL DEFAULT 0, validated_at INTEGER, output_product_id TEXT, external_production INTEGER NOT NULL DEFAULT 0, remainder_pieces INTEGER NOT NULL DEFAULT 0, scrap_depot_id TEXT, scrap_product_id TEXT, scrap_image BLOB)',
        );
        await database.execute(
          'CREATE TABLE stock_additions (id INTEGER PRIMARY KEY AUTOINCREMENT, product_id TEXT NOT NULL, depot_id TEXT NOT NULL DEFAULT \'general-depot\', pieces INTEGER NOT NULL, receipt_number TEXT NOT NULL, supplier_id TEXT, quantity REAL, unit TEXT, images TEXT NOT NULL DEFAULT \'[]\', created_at INTEGER NOT NULL, draft INTEGER NOT NULL DEFAULT 1)',
        );
        await database.execute(
          'CREATE TABLE depots (id TEXT PRIMARY KEY, name TEXT NOT NULL, image BLOB)',
        );
        await database.execute(
          'CREATE TABLE app_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
        );
        await _createStockPartnersTables(database);
        await _createStockTransfersTable(database);
        await _createSaleReturnsTable(database);
        await _createPayrollTable(database);
      },
      onUpgrade: (database, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await database.execute(
            'ALTER TABLE stock_additions ADD COLUMN created_at INTEGER NOT NULL DEFAULT 0',
          );
        }
        if (oldVersion < 3) {
          await database.execute(
            "ALTER TABLE products ADD COLUMN material_type TEXT NOT NULL DEFAULT 'steel'",
          );
          await database.execute(
            'CREATE TABLE categories (id TEXT PRIMARY KEY, name TEXT NOT NULL, product_ids TEXT NOT NULL, image BLOB)',
          );
        }
        if (oldVersion < 4) {
          await database.execute('ALTER TABLE machines ADD COLUMN category_id TEXT');
          await database.execute(
            "ALTER TABLE machines ADD COLUMN units TEXT NOT NULL DEFAULT '[]'",
          );
          await database.execute('ALTER TABLE operations ADD COLUMN product_id TEXT');
          await database.execute('ALTER TABLE operations ADD COLUMN machine_unit_number INTEGER');
        }
        if (oldVersion < 5) {
          await database.execute('ALTER TABLE operations ADD COLUMN remainder_image BLOB');
          await database.execute(
            'ALTER TABLE operations ADD COLUMN needs_review INTEGER NOT NULL DEFAULT 0',
          );
        }
        if (oldVersion < 6) {
          await database.execute('ALTER TABLE categories ADD COLUMN image BLOB');
        }
        if (oldVersion < 8) {
          await database.execute(
            'CREATE TABLE depots (id TEXT PRIMARY KEY, name TEXT NOT NULL, image BLOB)',
          );
          await database.execute(
            "ALTER TABLE products ADD COLUMN initial_depot_id TEXT NOT NULL DEFAULT 'general-depot'",
          );
          await database.execute(
            "ALTER TABLE stock_additions ADD COLUMN depot_id TEXT NOT NULL DEFAULT 'general-depot'",
          );
        }
        if (oldVersion < 9) {
          await database.execute(
            "ALTER TABLE operations ADD COLUMN source_depot_id TEXT NOT NULL DEFAULT 'general-depot'",
          );
          await database.execute('ALTER TABLE operations ADD COLUMN output_depot_id TEXT');
          await database.execute('ALTER TABLE operations ADD COLUMN remainder_depot_id TEXT');
        }
        if (oldVersion < 10) {
          await database.execute(
            "ALTER TABLE stock_additions ADD COLUMN receipt_number TEXT NOT NULL DEFAULT ''",
          );
        }
        if (oldVersion < 11) {
          await database.execute(
            'CREATE TABLE app_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
          );
        }
        if (oldVersion < 12) {
          await database.execute('ALTER TABLE stock_additions ADD COLUMN supplier_id TEXT');
          await database.execute('ALTER TABLE stock_additions ADD COLUMN quantity REAL');
          await database.execute('ALTER TABLE stock_additions ADD COLUMN unit TEXT');
          await database.execute(
            "ALTER TABLE stock_additions ADD COLUMN images TEXT NOT NULL DEFAULT '[]'",
          );
          await _createStockPartnersTables(database);
        }
        if (oldVersion < 13) {
          await database.execute(
            "ALTER TABLE products ADD COLUMN reference TEXT NOT NULL DEFAULT ''",
          );
        }
        if (oldVersion < 14) {
          await database.execute(
            "ALTER TABLE products ADD COLUMN kind TEXT NOT NULL DEFAULT 'standard'",
          );
          await database.execute(
            "UPDATE products SET kind = 'manufactured' WHERE manufactured = 1",
          );
        }
        if (oldVersion < 15) {
          await database.execute('ALTER TABLE products ADD COLUMN diameter REAL');
        }
        if (oldVersion < 16) {
          await database.execute(
            "ALTER TABLE products ADD COLUMN hose_unit TEXT NOT NULL DEFAULT 'piece'",
          );
          await database.execute(
            'ALTER TABLE products ADD COLUMN meters_per_piece REAL',
          );
          await database.execute('UPDATE products SET width = 1.5');
        }
        if (oldVersion < 17) {
          // Version 16 accidentally reversed the two pipe modes. Preserve
          // existing data while aligning it with the intended meaning.
          await database.execute(
            "UPDATE products SET hose_unit = 'meter' WHERE kind = 'hose' AND meters_per_piece IS NULL",
          );
          await database.execute(
            "UPDATE products SET hose_unit = 'piece' WHERE kind = 'hose' AND meters_per_piece IS NOT NULL",
          );
        }
        if (oldVersion < 18) {
          await database.execute(
            "ALTER TABLE users ADD COLUMN role TEXT NOT NULL DEFAULT 'operator'",
          );
          await database.execute("UPDATE users SET role = 'admin' WHERE admin = 1");
        }
        if (oldVersion < 19) {
          await database.execute(
            'ALTER TABLE stock_additions ADD COLUMN draft INTEGER NOT NULL DEFAULT 1',
          );
          await database.execute(
            'ALTER TABLE sales ADD COLUMN draft INTEGER NOT NULL DEFAULT 1',
          );
          await database.execute(
            'ALTER TABLE operations ADD COLUMN scrap_pieces INTEGER NOT NULL DEFAULT 0',
          );
          await database.execute(
            'ALTER TABLE operations ADD COLUMN completion_draft INTEGER NOT NULL DEFAULT 0',
          );
          await database.execute('UPDATE stock_additions SET draft = 0');
          await database.execute('UPDATE sales SET draft = 0');
        }
        if (oldVersion < 20) {
          await database.execute('ALTER TABLE operations ADD COLUMN validated_at INTEGER');
          await _createPayrollTable(database);
          await database.execute(
            'UPDATE operations SET validated_at = finished_at WHERE finished_at IS NOT NULL AND completion_draft = 0',
          );
        }
        if (oldVersion < 21) {
          await database.execute("ALTER TABLE users ADD COLUMN roles TEXT NOT NULL DEFAULT '[\"operator\"]'");
          await database.execute("ALTER TABLE users ADD COLUMN allowed_pages TEXT NOT NULL DEFAULT '[]'");
          await database.execute("ALTER TABLE users ADD COLUMN writable_pages TEXT NOT NULL DEFAULT '[]'");
          await database.execute("ALTER TABLE users ADD COLUMN status TEXT NOT NULL DEFAULT 'active'");
          await database.execute('ALTER TABLE users ADD COLUMN leave_until INTEGER');
          await database.execute('CREATE TABLE user_sessions (id TEXT PRIMARY KEY, user_id TEXT NOT NULL, logged_in_at INTEGER NOT NULL, logged_out_at INTEGER)');
          final legacyUsers = await database.query('users');
          for (final user in legacyUsers) {
            final legacyRole = user['role'] as String? ?? 'operator';
            final isAdmin = user['admin'] == 1;
            final roles = isAdmin ? {UserRole.admin} : {UserRole.values.byName(legacyRole)};
            final model = AppUser(
              id: user['id'] as String,
              username: user['username'] as String,
              password: user['password'] as String,
              fullName: user['full_name'] as String,
              admin: isAdmin,
              role: roles.first,
              roles: roles,
            );
            await database.update('users', {
              'roles': jsonEncode(model.roles.map((role) => role.name).toList()),
              'allowed_pages': jsonEncode(model.allowedPages.map((page) => page.name).toList()),
              'writable_pages': jsonEncode(model.writablePages.map((page) => page.name).toList()),
            }, where: 'id = ?', whereArgs: [model.id]);
          }
        }
        if (oldVersion < 22) {
          await database.execute('ALTER TABLE users ADD COLUMN failed_attempts INTEGER NOT NULL DEFAULT 0');
          await database.execute('ALTER TABLE users ADD COLUMN locked_until INTEGER');
        }
        if (oldVersion < 23) {
          await database.execute('ALTER TABLE products ADD COLUMN parent_product_id TEXT');
          await database.execute('ALTER TABLE operations ADD COLUMN output_product_id TEXT');
        }
        if (oldVersion < 24) {
          await _createSaleReturnsTable(database);
        }
        if (oldVersion < 25) {
          await database.execute('ALTER TABLE machines ADD COLUMN temporary INTEGER NOT NULL DEFAULT 0');
          await database.execute('ALTER TABLE machines ADD COLUMN deadline INTEGER');
          await database.execute('ALTER TABLE machines ADD COLUMN planned_pieces INTEGER');
          await database.execute('ALTER TABLE machines ADD COLUMN hopper_pieces INTEGER');
        }
        if (oldVersion < 26) {
          await database.execute('ALTER TABLE operations ADD COLUMN external_production INTEGER NOT NULL DEFAULT 0');
        }
        if (oldVersion < 27) {
          await database.execute('ALTER TABLE machines ADD COLUMN temporary_input_product_id TEXT');
          await database.execute('ALTER TABLE machines ADD COLUMN temporary_source_depot_id TEXT');
          await database.execute('ALTER TABLE machines ADD COLUMN temporary_input_pieces INTEGER');
        }
        if (oldVersion < 28) {
          // Existing returns had already affected stock before this workflow.
          await database.execute(
            "ALTER TABLE sale_returns ADD COLUMN status TEXT NOT NULL DEFAULT 'approved'",
          );
        }
        if (oldVersion < 29) {
          await database.execute(
            'ALTER TABLE users ADD COLUMN is_private_owner INTEGER NOT NULL DEFAULT 0',
          );
        }
        if (oldVersion < 30) {
          await _createStockTransfersTable(database);
        }
        if (oldVersion < 31) {
          await database.execute('ALTER TABLE operations ADD COLUMN remainder_pieces INTEGER NOT NULL DEFAULT 0');
          await database.execute('ALTER TABLE operations ADD COLUMN scrap_depot_id TEXT');
          await database.execute('ALTER TABLE operations ADD COLUMN scrap_product_id TEXT');
          await database.execute('ALTER TABLE operations ADD COLUMN scrap_image BLOB');
        }
      },
    );
    await database.insert('depots', const {
      'id': _generalDepotId,
      'name': 'Stock général',
      'image': null,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    await _migrateLegacyRecords(database);
    await _ensurePrivateOwner(database);
    await _removeManufacturedProductsFromCategories(database);
    return database;
  }

  Future<void> close() async {
    await (await _database).close();
  }

  /// Removes all locally stored application data, including account
  /// credentials. This must only be invoked from an authenticated recovery
  /// flow; it never creates a replacement account or password.
  Future<void> resetApplication() async {
    await (await _database).transaction((transaction) async {
      await transaction.delete('user_sessions');
      for (final table in _backupTables.reversed) {
        await transaction.delete(table);
      }
      await transaction.delete('app_settings');
      await transaction.delete('users');
      await transaction.insert('depots', const {
        'id': _generalDepotId,
        'name': 'Stock général',
        'image': null,
      });
    });
  }

  Future<List<AppUser>> loadUsers() async {
    final database = await _database;
    final rows = await database.query(
      'users',
      orderBy: 'admin DESC, full_name',
    );
    return rows.map(_userFromRow).toList();
  }

  Future<void> _createStockPartnersTables(DatabaseExecutor database) async {
    await database.execute(
      'CREATE TABLE suppliers (id TEXT PRIMARY KEY, name TEXT NOT NULL, company TEXT NOT NULL DEFAULT \'\', contact TEXT NOT NULL DEFAULT \'\', images TEXT NOT NULL DEFAULT \'[]\')',
    );
    await database.execute(
      'CREATE TABLE clients (id TEXT PRIMARY KEY, name TEXT NOT NULL DEFAULT \'\', company TEXT NOT NULL DEFAULT \'\', phone TEXT NOT NULL DEFAULT \'\', ice TEXT NOT NULL DEFAULT \'\', images TEXT NOT NULL DEFAULT \'[]\')',
    );
    await database.execute(
      'CREATE TABLE sales (id TEXT PRIMARY KEY, product_id TEXT NOT NULL, depot_id TEXT NOT NULL, client_id TEXT NOT NULL, pieces INTEGER NOT NULL, quantity REAL NOT NULL, unit TEXT NOT NULL, images TEXT NOT NULL DEFAULT \'[]\', created_at INTEGER NOT NULL, draft INTEGER NOT NULL DEFAULT 1)',
    );
  }

  Future<void> _createStockTransfersTable(DatabaseExecutor database) async {
    await database.execute(
      'CREATE TABLE stock_transfers (id TEXT PRIMARY KEY, product_id TEXT NOT NULL, source_depot_id TEXT NOT NULL, destination_depot_id TEXT NOT NULL, pieces INTEGER NOT NULL, created_at INTEGER NOT NULL, draft INTEGER NOT NULL DEFAULT 1)',
    );
  }

  /// Keep exactly one private owner: the first administrator created. Older
  /// builds may have accidentally marked more than one user as private, which
  /// would hide all of them from the team page.
  Future<void> _ensurePrivateOwner(DatabaseExecutor database) async {
    final admins = await database.query(
      'users', columns: ['id'], where: 'admin = 1', orderBy: 'rowid ASC', limit: 1,
    );
    final ownerId = admins.isEmpty ? null : admins.single['id'] as String;
    if (ownerId == null) {
      await database.update('users', {'is_private_owner': 0},
          where: 'is_private_owner != 0');
      return;
    }
    await database.update('users', {'is_private_owner': 0},
        where: 'id != ? AND is_private_owner != 0', whereArgs: [ownerId]);
    await database.update('users', {'is_private_owner': 1},
        where: 'id = ? AND is_private_owner != 1', whereArgs: [ownerId]);
  }

  Future<void> _createSaleReturnsTable(DatabaseExecutor database) async {
    await database.execute(
      "CREATE TABLE sale_returns (id TEXT PRIMARY KEY, sale_id TEXT NOT NULL, product_id TEXT NOT NULL, depot_id TEXT NOT NULL, pieces INTEGER NOT NULL, created_at INTEGER NOT NULL, status TEXT NOT NULL DEFAULT 'approved')",
    );
  }

  Future<void> _createPayrollTable(DatabaseExecutor database) async {
    await database.execute(
      'CREATE TABLE operator_payments (id TEXT PRIMARY KEY, operator_id TEXT NOT NULL, amount REAL NOT NULL, paid_at INTEGER NOT NULL)',
    );
  }

  Future<WorkshopData> loadWorkshop() async {
    final database = await _database;
    final products = (await database.query(
      'products',
      orderBy: 'name',
    )).map(_productFromRow).toList();
    final depots = (await database.query('depots', orderBy: 'name'))
        .map(_depotFromRow)
        .toList();
    final categories = (await database.query(
      'categories',
      orderBy: 'name',
    )).map(_categoryFromRow).toList();
    final machines = (await database.query(
      'machines',
      orderBy: 'name',
    )).map(_machineFromRow).toList();
    final operations = (await database.query(
      'operations',
      orderBy: 'started_at',
    )).map(_operationFromRow).toList();
    final stockAdditions = (await database.query(
      'stock_additions',
      orderBy: 'created_at DESC, id DESC',
    )).map(_stockAdditionFromRow).toList();
    final suppliers = (await database.query('suppliers', orderBy: 'name')).map(_supplierFromRow).toList();
    final clients = (await database.query('clients', orderBy: 'name, company')).map(_clientFromRow).toList();
    final sales = (await database.query('sales', orderBy: 'created_at DESC')).map(_saleFromRow).toList();
    final stockTransfers = (await database.query('stock_transfers', orderBy: 'created_at DESC')).map(_stockTransferFromRow).toList();
    final saleReturns = (await database.query('sale_returns', orderBy: 'created_at DESC')).map(_saleReturnFromRow).toList();
    final payments = (await database.query(
      'operator_payments',
      orderBy: 'paid_at DESC',
    )).map(_paymentFromRow).toList();
    final stockRows = await database.rawQuery(
      'SELECT product_id, SUM(pieces) AS pieces FROM stock_additions WHERE draft = 0 GROUP BY product_id',
    );
    final received = <String, int>{
      for (final row in stockRows)
        row['product_id'] as String: (row['pieces'] as num).toInt(),
    };
    return WorkshopData(
      products: products,
      depots: depots,
      categories: categories,
      machines: machines,
      operations: operations,
      stockAdditions: stockAdditions,
      suppliers: suppliers,
      clients: clients,
      sales: sales,
      stockTransfers: stockTransfers,
      saleReturns: saleReturns,
      payments: payments,
      received: received,
    );
  }

  Future<DateTime?> lastBackupAt() async {
    final rows = await (await _database).query(
      'app_settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: const ['last_backup_at'],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final timestamp = int.tryParse(rows.single['value'] as String);
    return timestamp == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(timestamp);
  }

  Future<void> recordSuccessfulBackup(DateTime time) async {
    await (await _database).insert('app_settings', {
      'key': 'last_backup_at',
      'value': time.millisecondsSinceEpoch.toString(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<bool> automaticBackupsEnabled() async {
    final rows = await (await _database).query(
      'app_settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: const ['automatic_backups_enabled'],
      limit: 1,
    );
    return rows.isNotEmpty && rows.single['value'] == 'true';
  }

  Future<void> setAutomaticBackupsEnabled(bool enabled) async {
    await (await _database).insert('app_settings', {
      'key': 'automatic_backups_enabled',
      'value': enabled.toString(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<double> meterRate() async {
    final rows = await (await _database).query(
      'app_settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: const ['operator_meter_rate'],
      limit: 1,
    );
    return rows.isEmpty ? 7 : number(rows.single['value'] as String? ?? '7');
  }

  Future<void> setMeterRate(double rate) async {
    await (await _database).insert('app_settings', {
      'key': 'operator_meter_rate',
      'value': rate.toString(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Uint8List> createBackup(String passphrase) async {
    final database = await _database;
    final tables = <String, Object?>{};
    for (final table in _backupTables) {
      final rows = await database.query(table);
      tables[table] = _encodeBackupRows(table, rows);
    }
    final raw = Uint8List.fromList(utf8.encode(jsonEncode({
      'format': _backupFormat,
      'version': _backupVersion,
      'created_at': DateTime.now().toIso8601String(),
      'tables': tables,
    })));
    final envelope = await PasswordSecurity.encryptBackup(raw, passphrase);
    return Uint8List.fromList(utf8.encode(jsonEncode({
      'format': _encryptedBackupFormat,
      'version': 1,
      ...envelope,
    })));
  }

  Future<void> restoreBackup(Uint8List bytes, String passphrase) async {
    final envelope = jsonDecode(utf8.decode(bytes));
    if (envelope is! Map || envelope['format'] != _encryptedBackupFormat || envelope['version'] != 1) {
      throw const FormatException('Cette sauvegarde n’est pas chiffrée ou est invalide.');
    }
    final decoded = jsonDecode(utf8.decode(await PasswordSecurity.decryptBackup(envelope, passphrase)));
    final backupVersion = decoded is Map ? decoded['version'] : null;
    if (decoded is! Map ||
        decoded['format'] != _backupFormat ||
        (backupVersion != 1 && backupVersion != 2 && backupVersion != _backupVersion) ||
        decoded['tables'] is! Map) {
      throw const FormatException('Fichier de sauvegarde FORAGE ZOUHOUR invalide.');
    }
    final rawTables = decoded['tables'] as Map;
    final restoredTables = <String, List<Map<String, Object?>>>{};
    for (final table in _backupTables) {
      final rawRows = rawTables[table];
      if (rawRows == null &&
          const {'suppliers', 'clients', 'sales', 'stock_transfers', 'sale_returns', 'operator_payments'}
              .contains(table)) {
        restoredTables[table] = const [];
        continue;
      }
      if (rawRows is! List) {
        throw const FormatException('La sauvegarde est incomplète.');
      }
      restoredTables[table] = _decodeBackupRows(table, rawRows);
    }

    await (await _database).transaction((transaction) async {
      for (final table in _backupTables.reversed) {
        await transaction.delete(table);
      }
      for (final table in _backupTables) {
        for (final row in restoredTables[table]!) {
          await transaction.insert(table, row);
        }
      }
      await transaction.insert('depots', const {
        'id': _generalDepotId,
        'name': 'Stock général',
        'image': null,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    });
  }

  Future<void> clearWorkshopData() async {
    await (await _database).transaction((transaction) async {
      for (final table in _backupTables.reversed) {
        if (table == 'users') continue;
        await transaction.delete(table);
      }
      await transaction.insert('depots', const {
        'id': _generalDepotId,
        'name': 'Stock général',
        'image': null,
      });
    });
  }

  List<Map<String, Object?>> _encodeBackupRows(
    String table,
    List<Map<String, Object?>> rows,
  ) {
    final binaryColumns = _binaryBackupColumns[table] ?? const <String>{};
    return rows
        .map(
          (row) => row.map(
            (key, value) => MapEntry(
              key,
              binaryColumns.contains(key) && value != null
                  ? base64Encode(value as Uint8List)
                  : value,
            ),
          ),
        )
        .toList();
  }

  List<Map<String, Object?>> _decodeBackupRows(
    String table,
    List<dynamic> rows,
  ) {
    final binaryColumns = _binaryBackupColumns[table] ?? const <String>{};
    return rows.map((rawRow) {
      if (rawRow is! Map) {
        throw const FormatException('La sauvegarde contient une ligne invalide.');
      }
      final row = <String, Object?>{};
      for (final entry in rawRow.entries) {
        final key = entry.key.toString();
        final value = entry.value;
        if (binaryColumns.contains(key) && value != null) {
          if (value is! String) {
            throw const FormatException('Une image de sauvegarde est invalide.');
          }
          row[key] = base64Decode(value);
        } else if (value is String || value is num || value is bool || value == null) {
          row[key] = value;
        } else {
          throw const FormatException('La sauvegarde contient une valeur invalide.');
        }
      }
      return row;
    }).toList();
  }

  /// A category contains only the raw products a machine can consume. This
  /// also cleans category data created by older versions of the application.
  Future<void> _removeManufacturedProductsFromCategories(
    Database database,
  ) async {
    final manufacturedRows = await database.query(
      'products',
      columns: ['id'],
      where: 'manufactured = ?',
      whereArgs: [1],
    );
    final manufacturedIds = manufacturedRows
        .map((row) => row['id'] as String)
        .toSet();
    if (manufacturedIds.isEmpty) return;

    final categoryRows = await database.query(
      'categories',
      columns: ['id', 'product_ids'],
    );
    for (final row in categoryRows) {
      final productIds = List<String>.from(
        jsonDecode(row['product_ids'] as String) as List,
      );
      final rawProductIds = productIds
          .where((id) => !manufacturedIds.contains(id))
          .toList();
      if (rawProductIds.length == productIds.length) continue;
      await database.update(
        'categories',
        {'product_ids': jsonEncode(rawProductIds)},
        where: 'id = ?',
        whereArgs: [row['id']],
      );
    }
  }

  Future<AppUser> insertUser(AppUser user) async {
    final protected = user.copyWith(password: await _passwordForStorage(user.password));
    await (await _database).insert('users', _userToRow(protected));
    return protected;
  }

  Future<AppUser> updateUser(AppUser user) async {
    final database = await _database;
    final protected = user.copyWith(password: await _passwordForStorage(user.password));
    if (!protected.isAdmin) {
      final admins = await database.query(
        'users',
        columns: ['id'],
        where: 'admin = 1 AND id != ?',
        whereArgs: [protected.id],
        limit: 1,
      );
      final current = await database.query('users', columns: ['admin'], where: 'id = ?', whereArgs: [protected.id], limit: 1);
      if (current.isNotEmpty && current.single['admin'] == 1 && admins.isEmpty) {
        throw StateError('Le dernier administrateur ne peut pas perdre ses droits.');
      }
    }
    await database.update('users', _userToRow(protected), where: 'id = ?', whereArgs: [protected.id]);
    return protected;
  }

  Future<LoginResult> authenticate(String username, String password) async {
    final database = await _database;
    final rows = await database.query(
      'users',
      where: 'LOWER(username) = ?',
      whereArgs: [username.trim().toLowerCase()],
      limit: 1,
    );
    if (rows.isEmpty) return const LoginResult.failure(LoginFailure.invalidCredentials);
    final row = rows.single;
    final user = _userFromRow(row);
    final now = DateTime.now();
    final lockedUntil = row['locked_until'] as int?;
    if (lockedUntil != null && lockedUntil > now.millisecondsSinceEpoch) {
      return const LoginResult.failure(LoginFailure.temporarilyLocked);
    }
    final storedPassword = row['password'] as String;
    // Users created before the security upgrade have a legacy plain-text
    // value. It is accepted once and immediately replaced with a hash.
    final verified = CredentialSecurity.isHash(storedPassword)
        ? await CredentialSecurity.verify(password, storedPassword)
        : _legacyConstantTimeEquals(password, storedPassword);
    if (!verified) {
      final attempts = (row['failed_attempts'] as int? ?? 0) + 1;
      final lockUntil = attempts >= _maximumFailedLogins
          ? now.add(_lockoutDuration).millisecondsSinceEpoch
          : null;
      await database.update(
        'users',
        {'failed_attempts': attempts, 'locked_until': lockUntil},
        where: 'id = ?',
        whereArgs: [user.id],
      );
      if (lockUntil != null) {
        return const LoginResult.failure(LoginFailure.temporarilyLocked);
      }
      return const LoginResult.failure(LoginFailure.invalidCredentials);
    }
    if (!user.canLogIn) {
      return const LoginResult.failure(LoginFailure.inactiveAccount);
    }
    final protected = CredentialSecurity.isHash(storedPassword)
        ? user
        : user.copyWith(password: await CredentialSecurity.hash(password));
    await database.update(
      'users',
      {
        'password': protected.password,
        'failed_attempts': 0,
        'locked_until': null,
      },
      where: 'id = ?',
      whereArgs: [user.id],
    );
    await recordLogin(user.id);
    return LoginResult.success(protected);
  }

  Future<String> _passwordForStorage(String value) =>
      CredentialSecurity.isHash(value) ? Future.value(value) : CredentialSecurity.hash(value);

  bool _legacyConstantTimeEquals(String left, String right) {
    final leftBytes = utf8.encode(left);
    final rightBytes = utf8.encode(right);
    if (leftBytes.length != rightBytes.length) return false;
    var difference = 0;
    for (var index = 0; index < leftBytes.length; index++) {
      difference |= leftBytes[index] ^ rightBytes[index];
    }
    return difference == 0;
  }
  Future<void> recordLogin(String userId) async {
    final database = await _database;
    final now = DateTime.now();
    // A previous application shutdown may not have emitted logout. Close that
    // stale session before starting a new, auditable one.
    await database.update('user_sessions', {'logged_out_at': now.millisecondsSinceEpoch}, where: 'user_id = ? AND logged_out_at IS NULL', whereArgs: [userId]);
    await database.insert('user_sessions', {
      'id': now.microsecondsSinceEpoch.toString(),
      'user_id': userId,
      'logged_in_at': now.millisecondsSinceEpoch,
    });
  }
  Future<void> recordLogout(String userId) async {
    final database = await _database;
    final sessions = await database.query('user_sessions', where: 'user_id = ? AND logged_out_at IS NULL', whereArgs: [userId], orderBy: 'logged_in_at DESC', limit: 1);
    if (sessions.isNotEmpty) {
      await database.update('user_sessions', {'logged_out_at': DateTime.now().millisecondsSinceEpoch}, where: 'id = ?', whereArgs: [sessions.first['id']]);
    }
  }
  Future<List<UserSession>> loadUserSessions(String userId) async => (await _database)
      .query('user_sessions', where: 'user_id = ?', whereArgs: [userId], orderBy: 'logged_in_at DESC')
      .then((rows) => rows.map((row) => UserSession(
        id: row['id'] as String, userId: row['user_id'] as String,
        loggedInAt: DateTime.fromMillisecondsSinceEpoch(row['logged_in_at'] as int),
        loggedOutAt: row['logged_out_at'] == null ? null : DateTime.fromMillisecondsSinceEpoch(row['logged_out_at'] as int),
      )).toList());
  Future<void> insertProduct(Product product) async =>
      (await _database).insert('products', _productToRow(product));
  Future<void> updateProduct(Product product) async =>
      (await _database).update('products', _productToRow(product), where: 'id = ?', whereArgs: [product.id]);
  Future<void> insertDepot(Depot depot) async =>
      (await _database).insert('depots', _depotToRow(depot));
  Future<void> insertCategory(ProductCategory category) async =>
      (await _database).insert('categories', _categoryToRow(category));
  Future<void> updateCategory(ProductCategory category) async =>
      (await _database).update(
        'categories',
        _categoryToRow(category),
        where: 'id = ?',
        whereArgs: [category.id],
      );
  Future<void> insertMachine(FactoryMachine machine) async =>
      (await _database).insert('machines', _machineToRow(machine));
  Future<void> updateMachine(FactoryMachine machine) async =>
      (await _database).update(
        'machines',
        _machineToRow(machine),
        where: 'id = ?',
        whereArgs: [machine.id],
      );
  Future<void> deleteMachine(String id) async =>
      (await _database).delete('machines', where: 'id = ?', whereArgs: [id]);
  Future<void> updateDepot(Depot depot) async =>
      (await _database).update('depots', _depotToRow(depot), where: 'id = ?', whereArgs: [depot.id]);
  Future<void> deleteDepot(String id) async {
    if (id == _generalDepotId) throw StateError('Le dépôt général ne peut pas être supprimé.');
    await (await _database).delete('depots', where: 'id = ?', whereArgs: [id]);
  }
  Future<void> insertOperation(Operation operation) async =>
      (await _database).insert('operations', _operationToRow(operation));
  Future<void> insertSupplier(Supplier supplier) async =>
      (await _database).insert('suppliers', _supplierToRow(supplier));
  Future<void> insertClient(Client client) async =>
      (await _database).insert('clients', _clientToRow(client));
  Future<void> insertSale(Sale sale) async =>
      (await _database).insert('sales', _saleToRow(sale));
  Future<void> insertSaleReturn(SaleReturn saleReturn) async =>
      (await _database).insert('sale_returns', _saleReturnToRow(saleReturn));
  Future<void> updateSaleReturn(SaleReturn saleReturn) async =>
      (await _database).update(
        'sale_returns',
        _saleReturnToRow(saleReturn),
        where: 'id = ?',
        whereArgs: [saleReturn.id],
      );
  Future<void> insertOperatorPayment(OperatorPayment payment) async =>
      (await _database).insert('operator_payments', _paymentToRow(payment));
  Future<StockAddition> addStock(StockAddition addition) async {
    final id = await (await _database).insert('stock_additions', {
        'product_id': addition.productId,
        'depot_id': addition.depotId,
        'pieces': addition.pieces,
        'receipt_number': addition.receiptNumber,
        'supplier_id': addition.supplierId,
        'quantity': addition.quantity,
        'unit': addition.unit.name,
        'images': _imagesToJson(addition.images),
        'created_at': addition.addedAt.millisecondsSinceEpoch,
        'draft': addition.draft ? 1 : 0,
      });
    return StockAddition(
      id: id,
      productId: addition.productId,
      depotId: addition.depotId,
      pieces: addition.pieces,
      receiptNumber: addition.receiptNumber,
      supplierId: addition.supplierId,
      quantity: addition.quantity,
      unit: addition.unit,
      images: addition.images,
      addedAt: addition.addedAt,
      draft: addition.draft,
    );
  }
  Future<void> updateStockAddition(StockAddition addition) async =>
      (await _database).update(
        'stock_additions',
        {
          'pieces': addition.pieces,
          'receipt_number': addition.receiptNumber,
          'quantity': addition.quantity,
          'unit': addition.unit.name,
          'draft': addition.draft ? 1 : 0,
        },
        where: 'id = ?',
        whereArgs: [addition.id],
      );
  Future<void> updateSale(Sale sale) async =>
      (await _database).update(
        'sales',
        _saleToRow(sale),
        where: 'id = ?',
        whereArgs: [sale.id],
      );
  Future<void> insertStockTransfer(StockTransfer transfer) async =>
      (await _database).insert('stock_transfers', _stockTransferToRow(transfer));
  Future<void> updateStockTransfer(StockTransfer transfer) async =>
      (await _database).update(
        'stock_transfers',
        _stockTransferToRow(transfer),
        where: 'id = ?',
        whereArgs: [transfer.id],
      );
  Future<void> deleteStockAddition(int id) async =>
      (await _database).delete('stock_additions', where: 'id = ?', whereArgs: [id]);
  Future<void> deleteStockTransfer(String id) async =>
      (await _database).delete('stock_transfers', where: 'id = ?', whereArgs: [id]);
  Future<void> deleteSaleReturn(String id) async =>
      (await _database).delete('sale_returns', where: 'id = ?', whereArgs: [id]);
  Future<void> deleteOperation(String id) async =>
      (await _database).delete('operations', where: 'id = ?', whereArgs: [id]);
  Future<void> deleteSaleAndReturns(String id) async {
    await (await _database).transaction((transaction) async {
      await transaction.delete('sale_returns', where: 'sale_id = ?', whereArgs: [id]);
      await transaction.delete('sales', where: 'id = ?', whereArgs: [id]);
    });
  }
  Future<void> deleteCategory(String id) async =>
      (await _database).delete('categories', where: 'id = ?', whereArgs: [id]);
  Future<void> deleteProductAndHistory(String id) async {
    final database = await _database;
    final machines = await database.query(
      'machines', columns: ['id'],
      where: 'output = ? OR inputs LIKE ?', whereArgs: [id, '%$id%'], limit: 1,
    );
    if (machines.isNotEmpty) {
      throw StateError('Supprimez ou modifiez d’abord les machines liées à ce produit.');
    }
    await database.transaction((transaction) async {
      await transaction.delete('stock_transfers', where: 'product_id = ?', whereArgs: [id]);
      await transaction.delete('sale_returns', where: 'product_id = ?', whereArgs: [id]);
      await transaction.delete('sales', where: 'product_id = ?', whereArgs: [id]);
      await transaction.delete('stock_additions', where: 'product_id = ?', whereArgs: [id]);
      await transaction.delete('operations', where: 'product_id = ? OR output_product_id = ?', whereArgs: [id, id]);
      final categories = await transaction.query('categories');
      for (final category in categories) {
        final productIds = List<String>.from(jsonDecode(category['product_ids'] as String) as List);
        if (!productIds.contains(id)) continue;
        await transaction.update('categories', {
          'product_ids': jsonEncode(productIds.where((item) => item != id).toList()),
        }, where: 'id = ?', whereArgs: [category['id']]);
      }
      await transaction.delete('products', where: 'id = ?', whereArgs: [id]);
    });
  }
  Future<void> adjustStock({
    required String productId,
    required String depotId,
    required int pieces,
  }) async {
    if (pieces == 0) return;
    await (await _database).insert('stock_additions', {
      'product_id': productId,
      'depot_id': depotId,
      'pieces': pieces,
      'receipt_number': 'Correction développeur',
      'quantity': pieces.toDouble(),
      'unit': InventoryUnit.piece.name,
      'images': '[]',
      'created_at': DateTime.now().millisecondsSinceEpoch,
      'draft': 0,
    });
  }
  Future<void> updateOperation(Operation operation) async =>
      (await _database).update(
        'operations',
        _operationToRow(operation),
        where: 'id = ?',
        whereArgs: [operation.id],
      );

  Map<String, Object?> _userToRow(AppUser user) => {
    'id': user.id,
    'username': user.username,
    'password': user.password,
    'full_name': user.fullName,
    'admin': user.isAdmin ? 1 : 0,
    'role': user.effectiveRole.name,
    'roles': jsonEncode(user.roles.map((role) => role.name).toList()),
    'allowed_pages': jsonEncode(user.allowedPages.map((page) => page.name).toList()),
    'writable_pages': jsonEncode(user.writablePages.map((page) => page.name).toList()),
    'status': user.status.name,
    'leave_until': user.leaveUntil?.millisecondsSinceEpoch,
    'is_private_owner': user.isPrivateOwner ? 1 : 0,
  };
  AppUser _userFromRow(Map<String, Object?> row) => AppUser(
    id: row['id'] as String,
    username: row['username'] as String,
    password: row['password'] as String,
    fullName: row['full_name'] as String,
    admin: row['admin'] == 1,
    role: UserRole.values.byName((row['role'] as String?) ?? (row['admin'] == 1 ? UserRole.admin.name : UserRole.operator.name)),
    roles: _rolesFromJson(row['roles'] as String?, row['role'] as String?, row['admin'] == 1),
    allowedPages: _pagesFromJson(row['allowed_pages'] as String?),
    writablePages: _pagesFromJson(row['writable_pages'] as String?),
    status: UserStatus.values.byName(row['status'] as String? ?? UserStatus.active.name),
    leaveUntil: row['leave_until'] == null ? null : DateTime.fromMillisecondsSinceEpoch(row['leave_until'] as int),
    isPrivateOwner: row['is_private_owner'] == 1,
  );

  Set<UserRole> _rolesFromJson(String? value, String? fallbackRole, bool isAdmin) {
    if (value != null) {
      final decoded = jsonDecode(value) as List;
      if (decoded.isNotEmpty) return decoded.map((item) => UserRole.values.byName(item as String)).toSet();
    }
    return {isAdmin ? UserRole.admin : UserRole.values.byName(fallbackRole ?? UserRole.operator.name)};
  }
  Set<AppPage>? _pagesFromJson(String? value) {
    if (value == null) return null;
    final decoded = jsonDecode(value) as List;
    if (decoded.isEmpty) return null;
    return decoded.map((item) => AppPage.values.byName(item as String)).toSet();
  }

  Map<String, Object?> _productToRow(Product product) => {
    'id': product.id,
    'name': product.name,
    'reference': product.reference,
    'width': product.width,
    'length_meters': product.lengthMeters,
    'length_unit': product.lengthUnit.name,
    'thickness': product.thickness,
    'manufactured': product.manufactured ? 1 : 0,
    'kind': product.kind.name,
    'diameter': product.diameter,
    'hose_unit': product.hoseUnit.name,
    'meters_per_piece': product.metersPerPiece,
    'initial_stock': product.initialStock,
    'initial_depot_id': product.initialDepotId,
    'material_type': product.material.name,
    'image': product.image,
    'parent_product_id': product.parentProductId,
  };
  Product _productFromRow(Map<String, Object?> row) => Product(
    id: row['id'] as String,
    name: row['name'] as String,
    reference: row['reference'] as String? ?? '',
    width: (row['width'] as num).toDouble(),
    lengthMeters: (row['length_meters'] as num).toDouble(),
    lengthUnit: LengthUnit.values.byName(row['length_unit'] as String),
    thickness: (row['thickness'] as num).toDouble(),
    kind: row['kind'] == null
        ? (row['manufactured'] == 1
              ? ProductKind.manufactured
              : ProductKind.standard)
        : ProductKind.values.byName(row['kind'] as String),
    diameter: (row['diameter'] as num?)?.toDouble(),
    hoseUnit: HoseUnit.values.byName(
      (row['hose_unit'] as String?) ?? HoseUnit.piece.name,
    ),
    metersPerPiece: (row['meters_per_piece'] as num?)?.toDouble(),
    initialStock: row['initial_stock'] as int,
    initialDepotId: row['initial_depot_id'] as String? ?? _generalDepotId,
    material: MaterialType.values.byName(
      (row['material_type'] as String?) ?? MaterialType.steel.name,
    ),
    image: row['image'] as Uint8List?,
    parentProductId: row['parent_product_id'] as String?,
  );

  Map<String, Object?> _depotToRow(Depot depot) => {
    'id': depot.id,
    'name': depot.name,
    'image': depot.image,
  };
  Depot _depotFromRow(Map<String, Object?> row) => Depot(
    id: row['id'] as String,
    name: row['name'] as String,
    image: row['image'] as Uint8List?,
  );

  Map<String, Object?> _categoryToRow(ProductCategory category) => {
    'id': category.id,
    'name': category.name,
    'product_ids': jsonEncode(category.productIds),
    'image': category.image,
  };
  ProductCategory _categoryFromRow(Map<String, Object?> row) =>
      ProductCategory(
        id: row['id'] as String,
        name: row['name'] as String,
        productIds: List<String>.from(
          jsonDecode(row['product_ids'] as String) as List,
        ),
        image: row['image'] as Uint8List? ?? Uint8List(0),
      );

  StockAddition _stockAdditionFromRow(Map<String, Object?> row) =>
      StockAddition(
        id: row['id'] as int?,
        productId: row['product_id'] as String,
        depotId: row['depot_id'] as String? ?? _generalDepotId,
        pieces: row['pieces'] as int,
        receiptNumber: row['receipt_number'] as String? ?? '',
        supplierId: row['supplier_id'] as String?,
        quantity: (row['quantity'] as num?)?.toDouble() ?? (row['pieces'] as num).toDouble(),
        unit: InventoryUnit.values.byName(
          (row['unit'] as String?) ?? InventoryUnit.piece.name,
        ),
        images: _imagesFromJson(row['images'] as String? ?? '[]'),
        addedAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
        draft: row['draft'] == 1,
      );

  Map<String, Object?> _supplierToRow(Supplier supplier) => {
    'id': supplier.id,
    'name': supplier.name,
    'company': supplier.company,
    'contact': supplier.contact,
    'images': _imagesToJson(supplier.images),
  };
  Supplier _supplierFromRow(Map<String, Object?> row) => Supplier(
    id: row['id'] as String,
    name: row['name'] as String,
    company: row['company'] as String? ?? '',
    contact: row['contact'] as String? ?? '',
    images: _imagesFromJson(row['images'] as String? ?? '[]'),
  );

  Map<String, Object?> _clientToRow(Client client) => {
    'id': client.id,
    'name': client.name,
    'company': client.company,
    'phone': client.phone,
    'ice': client.ice,
    'images': _imagesToJson(client.images),
  };
  Client _clientFromRow(Map<String, Object?> row) => Client(
    id: row['id'] as String,
    name: row['name'] as String? ?? '',
    company: row['company'] as String? ?? '',
    phone: row['phone'] as String? ?? '',
    ice: row['ice'] as String? ?? '',
    images: _imagesFromJson(row['images'] as String? ?? '[]'),
  );

  Map<String, Object?> _saleToRow(Sale sale) => {
    'id': sale.id,
    'product_id': sale.productId,
    'depot_id': sale.depotId,
    'client_id': sale.clientId,
    'pieces': sale.pieces,
    'quantity': sale.quantity,
    'unit': sale.unit.name,
    'images': _imagesToJson(sale.images),
    'created_at': sale.createdAt.millisecondsSinceEpoch,
    'draft': sale.draft ? 1 : 0,
  };
  Sale _saleFromRow(Map<String, Object?> row) => Sale(
    id: row['id'] as String,
    productId: row['product_id'] as String,
    depotId: row['depot_id'] as String,
    clientId: row['client_id'] as String,
    pieces: row['pieces'] as int,
    quantity: (row['quantity'] as num).toDouble(),
    unit: InventoryUnit.values.byName(row['unit'] as String),
    images: _imagesFromJson(row['images'] as String? ?? '[]'),
    createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
    draft: row['draft'] == 1,
  );
  Map<String, Object?> _stockTransferToRow(StockTransfer transfer) => {
    'id': transfer.id,
    'product_id': transfer.productId,
    'source_depot_id': transfer.sourceDepotId,
    'destination_depot_id': transfer.destinationDepotId,
    'pieces': transfer.pieces,
    'created_at': transfer.createdAt.millisecondsSinceEpoch,
    'draft': transfer.draft ? 1 : 0,
  };
  StockTransfer _stockTransferFromRow(Map<String, Object?> row) => StockTransfer(
    id: row['id'] as String,
    productId: row['product_id'] as String,
    sourceDepotId: row['source_depot_id'] as String,
    destinationDepotId: row['destination_depot_id'] as String,
    pieces: row['pieces'] as int,
    createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
    draft: row['draft'] == 1,
  );
  Map<String, Object?> _saleReturnToRow(SaleReturn saleReturn) => {
    'id': saleReturn.id,
    'sale_id': saleReturn.saleId,
    'product_id': saleReturn.productId,
    'depot_id': saleReturn.depotId,
    'pieces': saleReturn.pieces,
    'created_at': saleReturn.createdAt.millisecondsSinceEpoch,
    'status': saleReturn.status.name,
  };
  SaleReturn _saleReturnFromRow(Map<String, Object?> row) => SaleReturn(
    id: row['id'] as String,
    saleId: row['sale_id'] as String,
    productId: row['product_id'] as String,
    depotId: row['depot_id'] as String,
    pieces: row['pieces'] as int,
    createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
    status: switch (row['status'] as String? ?? 'approved') {
      'pending' => ReturnValidationStatus.pending,
      'rejected' => ReturnValidationStatus.rejected,
      _ => ReturnValidationStatus.approved,
    },
  );

  Map<String, Object?> _paymentToRow(OperatorPayment payment) => {
    'id': payment.id,
    'operator_id': payment.operatorId,
    'amount': payment.amount,
    'paid_at': payment.paidAt.millisecondsSinceEpoch,
  };
  OperatorPayment _paymentFromRow(Map<String, Object?> row) => OperatorPayment(
    id: row['id'] as String,
    operatorId: row['operator_id'] as String,
    amount: (row['amount'] as num).toDouble(),
    paidAt: DateTime.fromMillisecondsSinceEpoch(row['paid_at'] as int),
  );

  String _imagesToJson(List<Uint8List> images) =>
      jsonEncode(images.map(base64Encode).toList());
  List<Uint8List> _imagesFromJson(String value) {
    try {
      return (jsonDecode(value) as List)
          .whereType<String>()
          .map(base64Decode)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Map<String, Object?> _machineToRow(FactoryMachine machine) => {
    'id': machine.id,
    'name': machine.name,
    'copies': machine.copies,
    'type': machine.type.name,
    // Kept so installations created with the first version stay readable.
    'inputs': '[]',
    'output': machine.outputId,
    'operator_ids': jsonEncode(machine.operatorIds),
    // The legacy column must remain populated on old databases. Individual
    // pictures live in `units`; an empty blob represents a temporary machine.
    'image': machine.image ?? Uint8List(0),
    'category_id': machine.categoryId,
    'temporary': machine.temporary ? 1 : 0,
    'deadline': machine.deadline?.millisecondsSinceEpoch,
    'planned_pieces': machine.plannedPieces,
    'hopper_pieces': machine.hopperPieces,
    'temporary_input_product_id': machine.temporaryInputProductId,
    'temporary_source_depot_id': machine.temporarySourceDepotId,
    'temporary_input_pieces': machine.temporaryInputPieces,
    'units': jsonEncode(
      machine.units
          .map(
            (unit) => {
              'number': unit.number,
              'image': unit.image == null ? null : base64Encode(unit.image!),
              'state': unit.state.name,
              'until': unit.unavailableUntil?.millisecondsSinceEpoch,
            },
          )
          .toList(),
    ),
  };
  FactoryMachine _machineFromRow(Map<String, Object?> row) => FactoryMachine(
    id: row['id'] as String,
    name: row['name'] as String,
    type: MachineType.values.byName(row['type'] as String),
    categoryId: row['category_id'] as String? ?? 'legacy-category',
    outputId: row['output'] as String,
    units: _unitsFromJson(row['units'] as String? ?? '[]'),
    operatorIds: List<String>.from(
      jsonDecode(row['operator_ids'] as String) as List,
    ),
    image: (row['image'] as Uint8List?)?.isEmpty == true ? null : row['image'] as Uint8List?,
    temporary: row['temporary'] == 1,
    deadline: row['deadline'] == null ? null : DateTime.fromMillisecondsSinceEpoch(row['deadline'] as int),
    plannedPieces: row['planned_pieces'] as int?,
    hopperPieces: row['hopper_pieces'] as int?,
    temporaryInputProductId: row['temporary_input_product_id'] as String?,
    temporarySourceDepotId: row['temporary_source_depot_id'] as String?,
    temporaryInputPieces: row['temporary_input_pieces'] as int?,
  );

  List<MachineUnit> _unitsFromJson(String value) {
    final decoded = jsonDecode(value) as List;
    return decoded
        .map((item) {
          final map = Map<String, dynamic>.from(item as Map);
          return MachineUnit(
            number: map['number'] as int,
            image: map['image'] is String ? base64Decode(map['image'] as String) : null,
            state: MachineUnitState.values.byName(map['state'] as String),
            unavailableUntil: map['until'] == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(map['until'] as int),
          );
        })
        .toList();
  }

  Map<String, Object?> _operationToRow(Operation operation) => {
    'id': operation.id,
    'machine_id': operation.machineId,
    'operator_id': operation.operatorId,
    'pieces': operation.pieces,
    'product_id': operation.productId,
    'source_depot_id': operation.sourceDepotId,
    'output_depot_id': operation.outputDepotId,
    'remainder_depot_id': operation.remainderDepotId,
    'scrap_depot_id': operation.scrapDepotId,
    'scrap_product_id': operation.scrapProductId,
    'machine_unit_number': operation.machineUnitNumber,
    'hopper_pieces': operation.hopperPieces,
    'started_at': operation.startedAt.millisecondsSinceEpoch,
    'finished_at': operation.finishedAt?.millisecondsSinceEpoch,
    'output_pieces': operation.outputPieces,
    'final_image': operation.finalImage,
    'remainder_image': operation.remainderImage,
    'scrap_image': operation.scrapImage,
    'needs_review': operation.needsReview ? 1 : 0,
    'scrap_pieces': operation.scrapPieces,
    'remainder_pieces': operation.remainderPieces,
    'completion_draft': operation.completionDraft ? 1 : 0,
    'validated_at': operation.validatedAt?.millisecondsSinceEpoch,
    'output_product_id': operation.outputProductId,
    'external_production': operation.externalProduction ? 1 : 0,
  };
  Operation _operationFromRow(Map<String, Object?> row) => Operation(
    id: row['id'] as String,
    machineId: row['machine_id'] as String,
    operatorId: row['operator_id'] as String,
    pieces: row['pieces'] as int,
    productId: row['product_id'] as String,
    sourceDepotId: row['source_depot_id'] as String? ?? _generalDepotId,
    machineUnitNumber: row['machine_unit_number'] as int,
    hopperPieces: row['hopper_pieces'] as int?,
    startedAt: DateTime.fromMillisecondsSinceEpoch(row['started_at'] as int),
    finishedAt: row['finished_at'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(row['finished_at'] as int),
    outputPieces: row['output_pieces'] as int?,
    finalImage: row['final_image'] as Uint8List?,
    remainderImage: row['remainder_image'] as Uint8List?,
    scrapImage: row['scrap_image'] as Uint8List?,
    outputDepotId: row['output_depot_id'] as String?,
    remainderDepotId: row['remainder_depot_id'] as String?,
    scrapDepotId: row['scrap_depot_id'] as String?,
    scrapProductId: row['scrap_product_id'] as String?,
    needsReview: row['needs_review'] == 1,
    scrapPieces: row['scrap_pieces'] as int? ?? 0,
    remainderPieces: row['remainder_pieces'] as int? ?? 0,
    completionDraft: row['completion_draft'] == 1,
    validatedAt: row['validated_at'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(row['validated_at'] as int),
    outputProductId: row['output_product_id'] as String?,
    externalProduction: row['external_production'] == 1,
  );

  Future<void> _migrateLegacyRecords(Database database) async {
    const categoryId = 'legacy-category';
    final category = await database.query(
      'categories',
      where: 'id = ?',
      whereArgs: [categoryId],
    );
    if (category.isEmpty) {
      final products = await database.query('products', columns: ['id']);
      await database.insert('categories', {
        'id': categoryId,
        'name': 'Produits existants',
        'product_ids': jsonEncode(products.map((row) => row['id']).toList()),
        'image': Uint8List(0),
      });
    }
    final machines = await database.query('machines');
    for (final machine in machines) {
      final copies = machine['copies'] as int;
      final rawUnits = machine['units'] as String? ?? '[]';
      if (machine['category_id'] == null || rawUnits == '[]') {
        final units = rawUnits == '[]'
            ? List.generate(
                copies,
                (index) => {'number': index + 1, 'state': 'ready'},
              )
            : jsonDecode(rawUnits);
        await database.update(
          'machines',
          {'category_id': categoryId, 'units': jsonEncode(units)},
          where: 'id = ?',
          whereArgs: [machine['id']],
        );
      }
    }
    final operations = await database.query('operations');
    for (final operation in operations) {
      if (operation['product_id'] == null || operation['machine_unit_number'] == null) {
        final machineRows = await database.query(
          'machines',
          columns: ['output'],
          where: 'id = ?',
          whereArgs: [operation['machine_id']],
        );
        final productId = machineRows.isEmpty ? '' : machineRows.first['output'] as String;
        await database.update(
          'operations',
          {'product_id': productId, 'machine_unit_number': 1},
          where: 'id = ?',
          whereArgs: [operation['id']],
        );
      }
    }
  }
}

class ForageApp extends StatefulWidget {
  const ForageApp({super.key, this.database});

  final AppDatabase? database;

  @override
  State<ForageApp> createState() => _ForageAppState();
}

class _ForageAppState extends State<ForageApp> {
  late final AppDatabase database;
  var users = <AppUser>[];
  AppUser? current;
  var loading = true;

  @override
  void initState() {
    super.initState();
    database = widget.database ?? AppDatabase();
    loadUsers();
  }

  Future<void> loadUsers() async {
    final savedUsers = await database.loadUsers();
    if (mounted) {
      setState(() {
        users = savedUsers;
        current = null;
        loading = false;
      });
    }
  }

  Future<void> addUser(AppUser user) async {
    if (users.any((item) => item.username.toLowerCase() == user.username.toLowerCase())) {
      throw StateError('Ce nom d’utilisateur existe déjà.');
    }
    final protected = await database.insertUser(user);
    if (mounted) setState(() => users.add(protected));
  }

  Future<void> createFirstAdmin(AppUser user) async {
    if (users.isNotEmpty) {
      throw StateError('Un compte administrateur existe déjà.');
    }
    final protected = await database.insertUser(user);
    if (!mounted) return;
    setState(() {
      users.add(protected);
      // The first setup is part of an authenticated session. Going directly
      // to the workshop avoids forcing the owner to re-enter a just-created
      // credential and confirms that the account was saved successfully.
      current = protected;
    });
  }

  Future<void> updateUser(AppUser user) async {
    final protected = await database.updateUser(user);
    if (!mounted) return;
    setState(() {
      final index = users.indexWhere((item) => item.id == user.id);
      if (index >= 0) users[index] = protected;
      if (current?.id == user.id) current = protected;
    });
  }

  Future<LoginResult> login(String username, String password) async {
    final result = await database.authenticate(username, password);
    if (result.succeeded && mounted) setState(() => current = result.user);
    return result;
  }

  Future<void> logout() async {
    final user = current;
    if (user != null) await database.recordLogout(user.id);
    if (mounted) setState(() => current = null);
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'FORAGE ZOUHOUR',
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppPalette.primary,
        primary: AppPalette.primary,
        secondary: AppPalette.secondary,
        surface: Colors.white,
      ),
      scaffoldBackgroundColor: AppPalette.background,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: AppPalette.primary.withValues(alpha: .10)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: AppPalette.primary.withValues(alpha: .10)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: const BorderSide(color: AppPalette.primary, width: 1.5),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppPalette.primary,
          foregroundColor: Colors.white,
          minimumSize: const Size(0, 48),
          elevation: 0,
          shape: const StadiumBorder(),
          textStyle: const TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppPalette.primary,
          side: BorderSide(color: AppPalette.primary.withValues(alpha: .22)),
          shape: const StadiumBorder(),
        ),
      ),
    ),
    home: loading
        ? const Scaffold(body: Center(child: CircularProgressIndicator()))
        : current == null
        ? users.isEmpty
            ? InitialAdminSetup(onCreate: createFirstAdmin)
            : LoginPage(onLogin: login)
        : ForageHome(
            user: current!,
            users: users,
            database: database,
            onUserAdded: addUser,
            onUserUpdated: updateUser,
            onLogout: logout,
          ),
  );
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.onLogin});
  final Future<LoginResult> Function(String username, String password) onLogin;
  @override
  State<LoginPage> createState() => _LoginPageState();
}

/// First-run bootstrap. It is only displayed when the local database has no
/// users, so there is no hard-coded administrator or factory password.
class InitialAdminSetup extends StatefulWidget {
  const InitialAdminSetup({super.key, required this.onCreate});
  final Future<void> Function(AppUser) onCreate;
  @override
  State<InitialAdminSetup> createState() => _InitialAdminSetupState();
}

class _InitialAdminSetupState extends State<InitialAdminSetup> {
  final form = GlobalKey<FormState>();
  final fullName = TextEditingController();
  final username = TextEditingController();
  final password = TextEditingController();
  final confirmation = TextEditingController();
  bool saving = false;
  String? error;

  Future<void> create() async {
    if (!(form.currentState?.validate() ?? false)) return;
    setState(() { saving = true; error = null; });
    try {
      await widget.onCreate(AppUser(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        username: username.text.trim(),
        password: password.text,
        fullName: fullName.text.trim(),
        admin: true,
        role: UserRole.admin,
        roles: {UserRole.admin},
        isPrivateOwner: true,
      ));
    } catch (_) {
      if (mounted) setState(() => error = 'Impossible de créer ce compte. Choisissez un autre nom d’utilisateur.');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Aura(child: SafeArea(child: Center(child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 460),
      child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: Glass(
        padding: const EdgeInsets.all(22),
        child: Form(key: form, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Icon(Icons.admin_panel_settings_outlined, size: 48, color: AppPalette.primary),
          const SizedBox(height: 12),
          const Text('Créer le compte administrateur', textAlign: TextAlign.center, style: TextStyle(fontSize: 21, fontWeight: FontWeight.w900)),
          const SizedBox(height: 8),
          const Text('Cette étape n’apparaît qu’au premier lancement. Conservez ce mot de passe dans un gestionnaire sécurisé.', textAlign: TextAlign.center, style: TextStyle(color: AppPalette.muted)),
          const SizedBox(height: 20),
          TextFormField(controller: fullName, decoration: const InputDecoration(labelText: 'Nom complet *'), validator: required),
          const SizedBox(height: 12),
          TextFormField(controller: username, decoration: const InputDecoration(labelText: 'Nom d’utilisateur *'), validator: usernameValidator),
          const SizedBox(height: 12),
          TextFormField(controller: password, obscureText: true, decoration: const InputDecoration(labelText: 'Mot de passe *'), validator: securePasswordValidator),
          const SizedBox(height: 12),
          TextFormField(controller: confirmation, obscureText: true, decoration: const InputDecoration(labelText: 'Confirmer le mot de passe *'), validator: (value) => value == password.text ? null : 'Les mots de passe ne correspondent pas.'),
          if (error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(error!, style: const TextStyle(color: Color(0xFFB42318)))),
          const SizedBox(height: 20),
          FilledButton(onPressed: saving ? null : create, child: saving ? const CircularProgressIndicator() : const Text('Créer et continuer')),
        ])),
      )),
    )))),
  );
}

class _LoginPageState extends State<LoginPage> {
  final username = TextEditingController();
  final password = TextEditingController();
  String? error;
  var authenticating = false;

  Future<void> login() async {
    if (authenticating) return;
    setState(() {
      authenticating = true;
      error = null;
    });
    try {
      final result = await widget.onLogin(username.text, password.text);
      if (!mounted || result.succeeded) return;
      setState(() => error = switch (result.failure!) {
            LoginFailure.invalidCredentials => 'Mot de passe incorrect.',
            LoginFailure.temporarilyLocked =>
              'Compte temporairement verrouillé. Réessayez dans 15 minutes.',
            LoginFailure.inactiveAccount => 'Ce compte est en congé ou désactivé.',
          });
    } finally {
      if (mounted) setState(() => authenticating = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFFF8F9FC),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Stack(
            children: [
              Container(
                height: 270,
                decoration: const BoxDecoration(
                  color: Color(0xFF162238),
                  borderRadius: BorderRadius.vertical(bottom: Radius.circular(42)),
                ),
                child: Stack(
                  children: [
                    Positioned(
                      top: 22,
                      right: 24,
                      child: Image.asset(
                        'assets/app_logo.png',
                        width: 76,
                        height: 76,
                      ),
                    ),
                    Positioned(
                      top: -90,
                      right: -70,
                      child: Container(
                        width: 280,
                        height: 280,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: .045),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                    Positioned(
                      top: 48,
                      left: 24,
                      right: 24,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 58),
                          const Text('Bienvenue dans FORAGE ZOUHOUR', style: TextStyle(color: Colors.white, fontSize: 25, fontWeight: FontWeight.w900)),
                          const SizedBox(height: 7),
                          const Text('Connectez-vous pour gérer votre atelier.', style: TextStyle(color: Color(0xFF9CAAC0), fontSize: 13)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 218, 20, 28),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(22, 28, 22, 26),
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.all(Radius.circular(32)),
                  ),
                  child: Column(
                    children: [
                      const Align(alignment: Alignment.centerLeft, child: Text('Connexion', style: TextStyle(fontSize: 23, fontWeight: FontWeight.w900, color: Color(0xFF26354E)))),
                      const SizedBox(height: 6),
                      const Align(alignment: Alignment.centerLeft, child: Text('Entrez vos identifiants pour continuer.', style: TextStyle(color: AppPalette.muted))),
                      const SizedBox(height: 28),
                      TextField(
                        controller: username,
                        enabled: !authenticating,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          hintText: 'Nom d’utilisateur',
                          prefixIcon: Icon(Icons.person_outline_rounded),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: password,
                        enabled: !authenticating,
                        obscureText: true,
                        onSubmitted: authenticating ? null : (_) => login(),
                        decoration: const InputDecoration(hintText: 'Mot de passe', prefixIcon: Icon(Icons.lock_outline_rounded)),
                      ),
                      if (error != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(error!, style: const TextStyle(color: Color(0xFFB42318)))),
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 4),
                        child: Text(
                          'Contactez un administrateur pour toute récupération d’accès.',
                          style: TextStyle(fontSize: 12, color: AppPalette.muted),
                          textAlign: TextAlign.center,
                        ),
                      ),
                      const SizedBox(height: 14),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: authenticating ? null : login,
                          style: FilledButton.styleFrom(
                            minimumSize: const Size.fromHeight(54),
                            shape: const StadiumBorder(),
                          ),
                          child: authenticating
                              ? const SizedBox(
                                  height: 22,
                                  width: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.5,
                                    color: Colors.white,
                                  ),
                                )
                              : const Text('Connexion'),
                        ),
                      ),
                      const SizedBox(height: 22),
                      const Text('FORAGE ZOUHOUR · Gestion d’atelier', style: TextStyle(color: AppPalette.muted, fontSize: 12)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class ForageHome extends StatefulWidget {
  const ForageHome({
    super.key,
    required this.user,
    required this.users,
    required this.database,
    required this.onUserAdded,
    required this.onUserUpdated,
    required this.onLogout,
  });
  final AppUser user;
  final List<AppUser> users;
  final AppDatabase database;
  final Future<void> Function(AppUser) onUserAdded;
  final Future<void> Function(AppUser) onUserUpdated;
  final VoidCallback onLogout;
  @override
  State<ForageHome> createState() => _ForageHomeState();
}

class _ForageHomeState extends State<ForageHome> {
  int section = 0;
  var products = <Product>[];
  var depots = <Depot>[];
  var categories = <ProductCategory>[];
  var machines = <FactoryMachine>[];
  var operations = <Operation>[];
  var stockAdditions = <StockAddition>[];
  var suppliers = <Supplier>[];
  var clients = <Client>[];
  var sales = <Sale>[];
  var stockTransfers = <StockTransfer>[];
  var saleReturns = <SaleReturn>[];
  var payments = <OperatorPayment>[];
  var meterRate = 7.0;
  var received = <String, int>{};
  var loading = true;
  var _automaticBackupChecked = false;

  @override
  void initState() {
    super.initState();
    loadWorkshop();
  }

  Future<void> loadWorkshop() async {
    final data = await widget.database.loadWorkshop();
    final savedMeterRate = await widget.database.meterRate();
    if (mounted) {
      setState(() {
        products = data.products;
        depots = data.depots;
        categories = data.categories;
        machines = data.machines;
        operations = data.operations;
        stockAdditions = data.stockAdditions;
        suppliers = data.suppliers;
        clients = data.clients;
        sales = data.sales;
        stockTransfers = data.stockTransfers;
        saleReturns = data.saleReturns;
        payments = data.payments;
        meterRate = savedMeterRate > 0 ? savedMeterRate : 7;
        received = data.received;
        loading = false;
      });
      if (widget.user.isAdmin && !_automaticBackupChecked) {
        _automaticBackupChecked = true;
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _checkAutomaticBackup(),
        );
      }
    }
  }

  Future<bool> _downloadBackup({bool showSuccess = true}) async {
    try {
      final passphrase = await _requestBackupPassphrase(
        title: 'Chiffrer la sauvegarde',
        confirm: true,
      );
      if (passphrase == null) return false;
      final now = DateTime.now();
      final stamp = now.toIso8601String().replaceAll(RegExp('[:.]'), '-');
      final savedFile = await FilePicker.saveFile(
        dialogTitle: 'Télécharger la sauvegarde FORAGE ZOUHOUR',
        fileName: 'forage-zouhour-backup-$stamp.json',
        bytes: await widget.database.createBackup(passphrase),
        mimeType: 'application/json',
        type: FileType.custom,
        allowedExtensions: const ['json'],
      );
      if (savedFile == null) return false;
      await widget.database.recordSuccessfulBackup(now);
      if (mounted && showSuccess) {
        message(context, 'Sauvegarde téléchargée avec succès.');
      }
      return true;
    } catch (_) {
      if (mounted) {
        message(context, 'Impossible de télécharger la sauvegarde. Réessayez.');
      }
      return false;
    }
  }

  Future<void> _restoreBackup() async {
    try {
      final file = await FilePicker.pickFile(
        dialogTitle: 'Importer une sauvegarde FORAGE ZOUHOUR',
        type: FileType.custom,
        allowedExtensions: const ['json'],
      );
      if (file == null) return;
      final passphrase = await _requestBackupPassphrase(
        title: 'Ouvrir la sauvegarde',
      );
      if (passphrase == null) return;
      await widget.database.restoreBackup(await file.readAsBytes(), passphrase);
      await loadWorkshop();
      if (mounted) message(context, 'La sauvegarde a été restaurée.');
    } on FormatException catch (error) {
      if (mounted) message(context, error.message);
    } catch (_) {
      if (mounted) message(context, 'Impossible de restaurer cette sauvegarde.');
    }
  }

  Future<bool> _clearWorkshopData() async {
    final lastBackup = await widget.database.lastBackupAt();
    final hasRecentBackup =
        lastBackup != null && DateTime.now().difference(lastBackup).inDays < 5;
    if (!hasRecentBackup) {
      if (mounted) {
        message(
          context,
          'Téléchargez d’abord une nouvelle sauvegarde avant de supprimer les données.',
        );
      }
      return false;
    }
    await widget.database.clearWorkshopData();
    await loadWorkshop();
    if (mounted) message(context, 'Les données de l’atelier ont été supprimées.');
    return true;
  }

  Future<void> _checkAutomaticBackup() async {
    // An encrypted backup needs a passphrase and must never retain it on the
    // device. For that reason scheduled unencrypted exports are disabled.
    await widget.database.setAutomaticBackupsEnabled(false);
  }

  Future<String?> _requestBackupPassphrase({
    required String title,
    bool confirm = false,
  }) async {
    final password = TextEditingController();
    final confirmation = TextEditingController();
    String? error;
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(title),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text(
              'Utilisez un mot de passe robuste et conservez-le en lieu sûr : '
              'la sauvegarde ne peut pas être récupérée sans lui.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: password,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Mot de passe *'),
            ),
            if (confirm) ...[
              const SizedBox(height: 10),
              TextField(
                controller: confirmation,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Confirmer le mot de passe *',
                ),
              ),
            ],
            if (error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(error!, style: const TextStyle(color: Color(0xFFB42318)))),
          ]),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Annuler'),
            ),
            FilledButton(onPressed: () {
              final validation = securePasswordValidator(password.text);
              if (validation != null) { setState(() => error = validation); return; }
              if (confirm && password.text != confirmation.text) {
                setState(() => error = 'Les mots de passe ne correspondent pas.');
                return;
              }
              Navigator.pop(dialogContext, password.text);
            }, child: const Text('Continuer')),
          ],
        ),
      ),
    );
  }

  int stock(String productId) {
    return depots.fold(0, (total, depot) => total + depotStock(productId, depot.id));
  }

  int depotStock(String productId, String depotId) {
    final initial = product(productId)?.initialDepotId == depotId
        ? product(productId)?.initialStock ?? 0
        : 0;
    final added = stockAdditions
        .where((item) =>
            !item.draft &&
            item.productId == productId &&
            item.depotId == depotId)
        .fold(0, (total, item) => total + item.pieces);
    final manufactured = operations
        .where((op) =>
            !op.active &&
            !op.completionDraft &&
            (op.outputProductId ?? machine(op.machineId)?.outputId) == productId &&
            (op.outputDepotId ?? 'general-depot') == depotId)
        .fold(0, (total, op) => total + (op.outputPieces ?? 0));
    final consumed = operations
        .where((op) =>
            op.productId == productId &&
            op.sourceDepotId == depotId &&
            // An external job is only a proposal until the validator confirms
            // it; then its source material is deducted with the output entry.
            (!op.externalProduction || !op.completionDraft))
        .fold(0, (total, op) => total + op.pieces);
    final returned = operations
        .where((op) =>
            !op.active &&
            !op.completionDraft &&
            op.productId == productId &&
            op.remainderDepotId == depotId)
        .fold(0, (total, op) => total + op.remainderPieces);
    final scrap = operations
        .where((op) =>
            !op.active &&
            !op.completionDraft &&
            op.scrapProductId == productId &&
            op.scrapDepotId == depotId)
        .fold(0, (total, op) => total + op.scrapPieces);
    final sold = sales
        .where((sale) =>
            !sale.draft &&
            sale.productId == productId &&
            sale.depotId == depotId)
        .fold(0, (total, sale) => total + sale.pieces);
    final returnedByClients = saleReturns
        .where((item) =>
            item.status == ReturnValidationStatus.approved &&
            item.productId == productId &&
            item.depotId == depotId)
        .fold(0, (total, item) => total + item.pieces);
    final transferredOut = stockTransfers
        .where((item) => !item.draft && item.productId == productId && item.sourceDepotId == depotId)
        .fold(0, (total, item) => total + item.pieces);
    final transferredIn = stockTransfers
        .where((item) => !item.draft && item.productId == productId && item.destinationDepotId == depotId)
        .fold(0, (total, item) => total + item.pieces);
    return initial + added + manufactured - consumed + returned + scrap - sold + returnedByClients - transferredOut + transferredIn;
  }

  FactoryMachine? machine(String id) {
    for (final item in machines) {
      if (item.id == id) return item;
    }
    return null;
  }

  Product? product(String id) {
    for (final item in products) {
      if (item.id == id) return item;
    }
    return null;
  }

  ProductCategory? category(String id) {
    for (final item in categories) {
      if (item.id == id) return item;
    }
    return null;
  }

  Depot? depot(String id) {
    for (final item in depots) {
      if (item.id == id) return item;
    }
    return null;
  }

  AppUser? appUser(String id) {
    for (final item in widget.users) {
      if (item.id == id) return item;
    }
    return null;
  }

  Supplier? supplier(String id) {
    for (final item in suppliers) {
      if (item.id == id) return item;
    }
    return null;
  }

  Client? client(String id) {
    for (final item in clients) {
      if (item.id == id) return item;
    }
    return null;
  }

  bool get hasMyActiveOperation =>
      operations.any((op) => op.operatorId == widget.user.id && op.active);

  Product _producedVariant(Product template, Product source) {
    for (final product in products) {
      if (product.parentProductId == template.id &&
          product.width == source.width &&
          product.lengthMeters == source.lengthMeters &&
          product.lengthUnit == source.lengthUnit &&
          product.thickness == source.thickness &&
          product.material == source.material) {
        return product;
      }
    }
    final measures =
        '${formatNumber(source.lengthInChosenUnit)} ${source.lengthUnit.label} · '
        '${formatNumber(source.thickness)} mm';
    return Product(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: '${template.name} · $measures',
      reference: template.reference.isEmpty
          ? source.reference
          : template.reference,
      width: source.width,
      lengthMeters: source.lengthMeters,
      lengthUnit: source.lengthUnit,
      thickness: source.thickness,
      kind: ProductKind.manufactured,
      initialStock: 0,
      initialDepotId: 'general-depot',
      material: source.material,
      image: template.image,
      parentProductId: template.id,
    );
  }

  /// Waste is stocked independently from usable raw material.  One reusable
  /// waste product is kept for each source product, while every operation
  /// still records the depot and the picture that prove where it was placed.
  Product _scrapVariant(Product source) {
    final id = 'scrap-${source.id}';
    return products.firstWhere(
      (product) => product.id == id,
      orElse: () => Product(
        id: id,
        name: 'Déchets · ${source.name}',
        reference: source.reference,
        width: source.width,
        lengthMeters: source.lengthMeters,
        lengthUnit: source.lengthUnit,
        thickness: source.thickness,
        kind: ProductKind.standard,
        initialStock: 0,
        initialDepotId: 'general-depot',
        material: source.material,
        image: source.image,
        parentProductId: source.id,
      ),
    );
  }

  Future<void> addProduct() async {
    if (!widget.user.canWritePage(AppPage.products)) {
      return forbidden('Seul l’administrateur peut ajouter un produit.');
    }
    final kind = await Navigator.push<ProductKind>(
      context,
      MaterialPageRoute(builder: (_) => const ProductKindPage()),
    );
    if (kind == null || !mounted) return;
    final item = await Navigator.push<ProductCreation>(
      context,
      MaterialPageRoute(
        builder: (_) => ProductForm(
          kind: kind,
          depots: depots,
          categories: categories,
        ),
      ),
    );
    if (item != null) {
      await widget.database.insertProduct(item.product);
      if (item.categoryId != null) {
        final categoryIndex = categories.indexWhere(
          (category) => category.id == item.categoryId,
        );
        if (categoryIndex >= 0) {
          final category = categories[categoryIndex];
          final updated = ProductCategory(
            id: category.id,
            name: category.name,
            productIds: [...category.productIds, item.product.id],
            image: category.image,
          );
          await widget.database.updateCategory(updated);
          if (mounted) setState(() => categories[categoryIndex] = updated);
        }
      }
      if (mounted) setState(() => products.add(item.product));
      if (item.product.initialStock > 0) {
        await AppNotifications.show(
          title: 'Stock initial ajouté',
          body: '${productQuantityLabel(item.product, item.product.initialStock)} de ${item.product.name} ont été ajoutés.',
        );
      }
    }
  }

  Future<void> addStock({String? initialProductId}) async {
    if (!widget.user.canWritePage(AppPage.stock)) {
      return forbidden('Seul l’administrateur peut ajouter du stock.');
    }
    final item = await Navigator.push<StockAddition>(
      context,
      MaterialPageRoute(
        builder: (_) => StockForm(
          products: products.where((p) => !p.manufactured).toList(),
          stock: stock,
          depots: depots,
          suppliers: suppliers,
          onAddSupplier: addSupplier,
          initialProductId: initialProductId,
        ),
      ),
    );
    if (item != null) {
      final draft = await widget.database.addStock(item);
      if (mounted) {
        setState(() => stockAdditions = [draft, ...stockAdditions]);
        final productName = product(draft.productId)?.name ?? 'Produit';
        message(context, 'Achat enregistré comme brouillon : validation requise.');
        await AppNotifications.show(
          title: 'Achat en brouillon',
          body: '${formatQuantity(draft.quantity, draft.unit)} de $productName attend une validation.',
        );
      }
    }
  }

  Future<void> addStockFor(Product product) async {
    if (product.manufactured) {
      return forbidden(
        'Le stock des produits fabriqués est ajouté à la fin d’une opération.',
      );
    }
    await addStock(initialProductId: product.id);
  }

  Future<Supplier?> addSupplier() async {
    final item = await Navigator.push<Supplier>(
      context,
      MaterialPageRoute(builder: (_) => const SupplierForm()),
    );
    if (item != null) {
      await widget.database.insertSupplier(item);
      if (mounted) setState(() => suppliers.add(item));
    }
    return item;
  }

  Future<Client?> addClient() async {
    final item = await Navigator.push<Client>(
      context,
      MaterialPageRoute(builder: (_) => const ClientForm()),
    );
    if (item != null) {
      await widget.database.insertClient(item);
      if (mounted) setState(() => clients.add(item));
    }
    return item;
  }

  Future<void> addSale() async {
    if (!widget.user.canWritePage(AppPage.stock)) {
      return forbidden('Seul l’administrateur peut enregistrer une vente.');
    }
    final item = await Navigator.push<Sale>(
      context,
      MaterialPageRoute(
        builder: (_) => SaleForm(
          products: products,
          depots: depots,
          clients: clients,
          available: depotStock,
          onAddClient: addClient,
        ),
      ),
    );
    if (item == null) return;
    await widget.database.insertSale(item);
    if (mounted) {
      setState(() => sales = [item, ...sales]);
      message(context, 'Vente enregistrée comme brouillon : validation requise.');
    }
  }

  Future<SaleReturn?> returnSale(Sale sale, int pieces) async {
    if (!widget.user.canWritePage(AppPage.stock)) {
      forbidden('Vous n’avez pas le droit d’enregistrer un retour.');
      return null;
    }
    if (sale.draft) {
      forbidden('Validez d’abord cette vente avant d’enregistrer un retour.');
      return null;
    }
    final alreadyReturned = saleReturns
        .where((item) =>
            item.saleId == sale.id &&
            item.status != ReturnValidationStatus.rejected)
        .fold(0, (total, item) => total + item.pieces);
    final remaining = sale.pieces - alreadyReturned;
    if (pieces <= 0 || pieces > remaining) {
      forbidden('La quantité retournée doit être comprise entre 1 et $remaining.');
      return null;
    }
    final item = SaleReturn(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      saleId: sale.id,
      productId: sale.productId,
      depotId: sale.depotId,
      pieces: pieces,
      createdAt: DateTime.now(),
      status: ReturnValidationStatus.pending,
    );
    await widget.database.insertSaleReturn(item);
    if (mounted) {
      setState(() => saleReturns = [item, ...saleReturns]);
      message(context, 'Retour envoyé à la validation : le stock ne changera qu’après acceptation.');
      await AppNotifications.show(
        title: 'Retour client à valider',
        body: 'Un retour de ${product(sale.productId)?.name ?? 'produit'} attend votre contrôle.',
      );
    }
    return item;
  }

  void openStockRecords() {
    Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => StockRecordsPage(
          products: products,
          additions: stockAdditions,
          sales: sales,
          saleReturns: saleReturns,
          suppliers: suppliers,
          clients: clients,
          depotName: (id) => depot(id)?.name ?? 'Stock général',
          canReturn: widget.user.canWritePage(AppPage.stock),
          onReturn: returnSale,
        ),
      ),
    );
  }

  Future<void> addDepot() async {
    if (!widget.user.canWritePage(AppPage.stock)) {
      return forbidden('Vous n’avez pas le droit de modifier les dépôts.');
    }
    final item = await Navigator.push<Depot>(
      context,
      MaterialPageRoute(builder: (_) => const DepotForm()),
    );
    if (item != null) {
      await widget.database.insertDepot(item);
      if (mounted) setState(() => depots.add(item));
    }
  }

  Future<void> createStockTransfer() async {
    if (!widget.user.isAdmin) {
      return forbidden('Seul l’administrateur peut demander un transfert.');
    }
    final transfer = await Navigator.push<StockTransfer>(
      context,
      MaterialPageRoute(
        builder: (_) => StockTransferForm(
          products: products,
          depots: depots,
          available: depotStock,
        ),
      ),
    );
    if (transfer == null) return;
    await widget.database.insertStockTransfer(transfer);
    if (mounted) {
      setState(() => stockTransfers = [transfer, ...stockTransfers]);
      message(context, 'Transfert enregistré en brouillon : validation requise.');
    }
  }

  Future<void> addMachine() async {
    if (!widget.user.canWritePage(AppPage.machines)) {
      return forbidden('Seul l’administrateur peut ajouter une machine.');
    }
    final item = await Navigator.push<FactoryMachine>(
      context,
      MaterialPageRoute(
        builder: (_) => MachineForm(
          categories: categories,
          products: products,
          users: widget.users,
          onUserAdded: widget.onUserAdded,
          canManageUsers: widget.user.isAdmin,
          canCreateTemporary: widget.user.isAdmin,
          depots: depots,
          available: depotStock,
        ),
      ),
    );
    if (item != null) {
      final same = machines.where(
        (machine) =>
            machine.name.trim().toLowerCase() == item.name.trim().toLowerCase() &&
            machine.categoryId == item.categoryId,
      );
      if (same.isNotEmpty && !item.temporary) {
        final existing = same.first;
        final startNumber = existing.units.length;
        final merged = FactoryMachine(
          id: existing.id,
          name: existing.name,
          type: existing.type,
          categoryId: existing.categoryId,
          outputId: existing.outputId,
          units: [
            ...existing.units,
            ...List.generate(
              item.copies,
              (index) => MachineUnit(
                number: startNumber + index + 1,
                image: item.units[index].image,
              ),
            ),
          ],
          operatorIds: existing.operatorIds,
          image: existing.image,
        );
        await widget.database.updateMachine(merged);
        if (mounted) setState(() => machines[machines.indexOf(existing)] = merged);
        if (mounted) message(context, 'Exemplaires ajoutés à ${existing.name}.');
      } else {
        await widget.database.insertMachine(item);
        if (mounted) setState(() => machines.add(item));
        if (item.temporary) {
          final outputQuantity = item.plannedPieces ?? 0;
          final inputQuantity = item.temporaryInputPieces ?? 0;
          final operation = Operation(
            id: '${item.id}-external',
            machineId: item.id,
            operatorId: '',
            productId: item.temporaryInputProductId!,
            sourceDepotId: item.temporarySourceDepotId!,
            machineUnitNumber: 1,
            pieces: inputQuantity,
            hopperPieces: item.hopperPieces,
            startedAt: DateTime.now(),
            finishedAt: DateTime.now(),
            outputPieces: outputQuantity,
            outputDepotId: 'general-depot',
            completionDraft: true,
            outputProductId: item.outputId,
            externalProduction: true,
          );
          await widget.database.insertOperation(operation);
          if (mounted) setState(() => operations.add(operation));
          await AppNotifications.show(
            title: 'Travail externe à valider',
            body: '${item.name} attend la validation administrative.',
          );
        }
      }
    }
  }

  Future<void> addCategory() async {
    if (!widget.user.canWritePage(AppPage.products)) return forbidden('Vous n’avez pas le droit de modifier les produits.');
    final item = await Navigator.push<ProductCategory>(
      context,
      MaterialPageRoute(builder: (_) => const CategoryForm()),
    );
    if (item != null) {
      await widget.database.insertCategory(item);
      if (mounted) setState(() => categories.add(item));
    }
  }

  Future<void> editCategory(ProductCategory value) async {
    if (!widget.user.canWritePage(AppPage.products)) return forbidden('Vous n’avez pas le droit de modifier les produits.');
    final item = await Navigator.push<ProductCategory>(
      context,
      MaterialPageRoute(builder: (_) => CategoryForm(initial: value)),
    );
    if (item != null) {
      await widget.database.updateCategory(item);
      if (mounted) setState(() => categories[categories.indexOf(value)] = item);
    }
  }

  Future<void> manageMachine(FactoryMachine value) async {
    if (!widget.user.canWritePage(AppPage.machines)) {
      return forbidden('Vous n’avez pas le droit de gérer les machines.');
    }
    final updated = await Navigator.push<FactoryMachine>(
      context,
      MaterialPageRoute(builder: (_) => MachineUnitsPage(machine: value)),
    );
    if (updated != null) {
      await widget.database.updateMachine(updated);
      if (mounted) setState(() => machines[machines.indexOf(value)] = updated);
    }
  }

  void forbidden(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  Future<void> start(FactoryMachine item, MachineUnit unit) async {
    if (!widget.user.isOperator || !widget.user.canWritePage(AppPage.machines) || !item.operatorIds.contains(widget.user.id)) {
      return forbidden('Cette machine est réservée à son opérateur assigné.');
    }
    final operation = await Navigator.push<Operation>(
      context,
      MaterialPageRoute(
        builder: (_) => StartOperation(
          machine: item,
          available: depotStock,
          user: widget.user,
          category: category(item.categoryId),
          products: products,
          depots: depots,
          unitNumber: unit.number,
        ),
      ),
    );
    if (operation != null) {
      await widget.database.insertOperation(operation);
      if (mounted) setState(() => operations.add(operation));
      await AppNotifications.show(
        title: 'Opération démarrée',
        body: '${widget.user.fullName} a démarré une opération sur ${item.name}.',
      );
    }
  }

  Future<void> finish(Operation operation) async {
    if (!widget.user.isOperator || !widget.user.canWritePage(AppPage.machines) || operation.operatorId != widget.user.id) {
      return forbidden('Seul l’opérateur ayant démarré cette opération peut la terminer.');
    }
    final item = machine(operation.machineId)!;
    final template = product(item.outputId)!;
    final source = product(operation.productId)!;
    final completion = await Navigator.push<Completion>(
      context,
      MaterialPageRoute(
        builder: (_) => FinishOperation(
          operation: operation,
          machine: item,
          output: template,
          depots: depots,
        ),
      ),
    );
    if (completion == null) return;
    final output = _producedVariant(template, source);
    if (!products.any((product) => product.id == output.id)) {
      await widget.database.insertProduct(output);
      if (mounted) setState(() => products.add(output));
    }
    Product? scrapProduct;
    if (completion.scrapPieces > 0) {
      final wasteProduct = _scrapVariant(source);
      scrapProduct = wasteProduct;
      if (!products.any((product) => product.id == wasteProduct.id)) {
        await widget.database.insertProduct(wasteProduct);
        if (mounted) setState(() => products.add(wasteProduct));
      }
    }
    setState(() {
      operation.outputPieces = completion.outputPieces;
      operation.scrapPieces = completion.scrapPieces;
      operation.finalImage = completion.image;
      operation.remainderImage = completion.remainderImage;
      operation.scrapImage = completion.scrapImage;
      operation.needsReview = false;
      operation.completionDraft = true;
      operation.outputDepotId = completion.outputDepotId;
      operation.remainderDepotId = completion.remainderDepotId;
      operation.remainderPieces = completion.remainderPieces;
      operation.scrapDepotId = completion.scrapDepotId;
      operation.scrapProductId = scrapProduct?.id;
      operation.finishedAt = completion.finishedAt;
      operation.outputProductId = output.id;
    });
    await widget.database.updateOperation(operation);
    await AppNotifications.show(
      title: 'Fin de production en brouillon',
      body: 'L’opération sur ${item.name} attend la validation finale.',
    );
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => Receipt(
        operation: operation,
        machine: item,
        output: output,
        operator: widget.user,
      ),
    );
  }

  Future<void> approveReview(Operation operation, String depotId) async {
    if (!widget.user.isAdmin) return forbidden('Seul l’administrateur peut valider ce contrôle.');
    operation.remainderDepotId = depotId;
    operation.needsReview = false;
    await widget.database.updateOperation(operation);
    await AppNotifications.show(
      title: 'Contrôle validé',
      body: 'Les pièces restantes ont été affectées au dépôt ${depot(depotId)?.name ?? 'sélectionné'}.',
    );
    if (!mounted) return;
    setState(() {});
    message(context, 'Le reste a été accepté et l’opération est terminée.');
  }

  Future<void> approveStockDraft(StockAddition draft) async {
    if (!widget.user.canValidate || !widget.user.canWritePage(AppPage.validation)) return forbidden('Vous n’avez pas le droit de valider.');
    final approved = StockAddition(
      id: draft.id,
      productId: draft.productId,
      depotId: draft.depotId,
      pieces: draft.pieces,
      receiptNumber: draft.receiptNumber,
      supplierId: draft.supplierId,
      quantity: draft.quantity,
      unit: draft.unit,
      images: draft.images,
      addedAt: draft.addedAt,
      draft: false,
    );
    await widget.database.updateStockAddition(approved);
    if (!mounted) return;
    setState(() {
      stockAdditions[stockAdditions.indexWhere((item) => item.id == draft.id)] = approved;
      received[approved.productId] = (received[approved.productId] ?? 0) + approved.pieces;
    });
    message(context, 'Achat validé et ajouté au stock.');
  }

  Future<void> updateStockDraft(StockAddition draft) async {
    if (!widget.user.canValidate || !widget.user.canWritePage(AppPage.validation)) return forbidden('Vous n’avez pas le droit de modifier ce brouillon.');
    await widget.database.updateStockAddition(draft);
    if (!mounted) return;
    setState(() => stockAdditions[stockAdditions.indexWhere((item) => item.id == draft.id)] = draft);
  }

  Future<void> cancelStockDraft(StockAddition draft) async {
    if (!widget.user.canValidate || !widget.user.canWritePage(AppPage.validation)) return forbidden('Vous n’avez pas le droit d’annuler ce brouillon.');
    if (draft.id == null) return;
    await widget.database.deleteStockAddition(draft.id!);
    if (mounted) setState(() => stockAdditions.removeWhere((item) => item.id == draft.id));
  }

  Future<void> approveSaleDraft(Sale draft) async {
    if (!widget.user.canValidate || !widget.user.canWritePage(AppPage.validation)) return forbidden('Vous n’avez pas le droit de valider.');
    if (draft.pieces > depotStock(draft.productId, draft.depotId)) {
      return forbidden('Le stock disponible est insuffisant pour valider cette vente.');
    }
    final approved = Sale(
      id: draft.id,
      productId: draft.productId,
      depotId: draft.depotId,
      clientId: draft.clientId,
      pieces: draft.pieces,
      quantity: draft.quantity,
      unit: draft.unit,
      images: draft.images,
      createdAt: draft.createdAt,
      draft: false,
    );
    await widget.database.updateSale(approved);
    if (!mounted) return;
    setState(() => sales[sales.indexWhere((item) => item.id == draft.id)] = approved);
    message(context, 'Vente validée et déduite du stock.');
  }

  Future<void> approveStockTransfer(StockTransfer draft) async {
    if (!widget.user.canValidate || !widget.user.canWritePage(AppPage.validation)) {
      return forbidden('Vous n’avez pas le droit de valider.');
    }
    if (draft.pieces <= 0 || draft.sourceDepotId == draft.destinationDepotId ||
        draft.pieces > depotStock(draft.productId, draft.sourceDepotId)) {
      return forbidden('Le stock disponible dans le dépôt de départ est insuffisant.');
    }
    final approved = StockTransfer(
      id: draft.id,
      productId: draft.productId,
      sourceDepotId: draft.sourceDepotId,
      destinationDepotId: draft.destinationDepotId,
      pieces: draft.pieces,
      createdAt: draft.createdAt,
      draft: false,
    );
    await widget.database.updateStockTransfer(approved);
    if (mounted) {
      setState(() => stockTransfers[stockTransfers.indexWhere((item) => item.id == draft.id)] = approved);
      message(context, 'Transfert validé : le stock a été déplacé.');
    }
  }

  Future<void> updateSaleDraft(Sale draft) async {
    if (!widget.user.canValidate || !widget.user.canWritePage(AppPage.validation)) return forbidden('Vous n’avez pas le droit de modifier ce brouillon.');
    await widget.database.updateSale(draft);
    if (!mounted) return;
    setState(() => sales[sales.indexWhere((item) => item.id == draft.id)] = draft);
  }

  Future<void> cancelSaleDraft(Sale draft) async {
    if (!widget.user.canValidate || !widget.user.canWritePage(AppPage.validation)) return forbidden('Vous n’avez pas le droit d’annuler ce brouillon.');
    await widget.database.deleteSaleAndReturns(draft.id);
    if (mounted) {
      setState(() {
        sales.removeWhere((item) => item.id == draft.id);
        saleReturns.removeWhere((item) => item.saleId == draft.id);
      });
    }
  }

  Future<void> approveSaleReturn(SaleReturn draft) async {
    if (!widget.user.canValidate || !widget.user.canWritePage(AppPage.validation)) {
      return forbidden('Vous n’avez pas le droit de valider.');
    }
    final sale = sales.where((item) => item.id == draft.saleId).firstOrNull;
    if (sale == null || sale.draft) {
      return forbidden('La vente associée à ce retour n’est pas valide.');
    }
    final otherReturns = saleReturns
        .where((item) =>
            item.saleId == draft.saleId &&
            item.id != draft.id &&
            item.status != ReturnValidationStatus.rejected)
        .fold(0, (total, item) => total + item.pieces);
    if (draft.pieces <= 0 || otherReturns + draft.pieces > sale.pieces) {
      return forbidden('La quantité retournée dépasse la quantité vendue.');
    }
    final approved = SaleReturn(
      id: draft.id,
      saleId: draft.saleId,
      productId: draft.productId,
      depotId: draft.depotId,
      pieces: draft.pieces,
      createdAt: draft.createdAt,
      status: ReturnValidationStatus.approved,
    );
    await widget.database.updateSaleReturn(approved);
    if (!mounted) return;
    setState(() => saleReturns[saleReturns.indexWhere((item) => item.id == draft.id)] = approved);
    message(context, 'Retour validé et ajouté au stock.');
  }

  Future<void> updateSaleReturn(SaleReturn draft) async {
    if (!widget.user.canValidate || !widget.user.canWritePage(AppPage.validation)) {
      return forbidden('Vous n’avez pas le droit de modifier ce retour.');
    }
    final sale = sales.where((item) => item.id == draft.saleId).firstOrNull;
    final otherReturns = saleReturns
        .where((item) =>
            item.saleId == draft.saleId &&
            item.id != draft.id &&
            item.status != ReturnValidationStatus.rejected)
        .fold(0, (total, item) => total + item.pieces);
    if (sale == null || draft.pieces <= 0 || otherReturns + draft.pieces > sale.pieces) {
      return forbidden('La quantité retournée dépasse la quantité vendue.');
    }
    await widget.database.updateSaleReturn(draft);
    if (!mounted) return;
    setState(() => saleReturns[saleReturns.indexWhere((item) => item.id == draft.id)] = draft);
  }

  Future<void> rejectSaleReturn(SaleReturn draft) async {
    if (!widget.user.canValidate || !widget.user.canWritePage(AppPage.validation)) {
      return forbidden('Vous n’avez pas le droit de refuser ce retour.');
    }
    final rejected = SaleReturn(
      id: draft.id,
      saleId: draft.saleId,
      productId: draft.productId,
      depotId: draft.depotId,
      pieces: draft.pieces,
      createdAt: draft.createdAt,
      status: ReturnValidationStatus.rejected,
    );
    await widget.database.updateSaleReturn(rejected);
    if (!mounted) return;
    setState(() => saleReturns[saleReturns.indexWhere((item) => item.id == draft.id)] = rejected);
    message(context, 'Retour refusé : le stock reste inchangé.');
  }

  Future<void> cancelSaleReturn(SaleReturn draft) async {
    if (!widget.user.canValidate || !widget.user.canWritePage(AppPage.validation)) return forbidden('Vous n’avez pas le droit d’annuler ce retour.');
    await widget.database.deleteSaleReturn(draft.id);
    if (mounted) setState(() => saleReturns.removeWhere((item) => item.id == draft.id));
  }

  Future<void> approveOperationDraft(Operation draft) async {
    if (!widget.user.canValidate || !widget.user.canWritePage(AppPage.validation)) return forbidden('Vous n’avez pas le droit de valider.');
    draft.completionDraft = false;
    draft.validatedAt = DateTime.now();
    await widget.database.updateOperation(draft);
    if (draft.externalProduction) {
      // A temporary external machine represents one shipment only. The
      // operation remains in the history, while its temporary card vanishes.
      await widget.database.deleteMachine(draft.machineId);
    }
    if (!mounted) return;
    setState(() {
      if (draft.externalProduction) {
        machines.removeWhere((machine) => machine.id == draft.machineId);
      }
    });
    message(context, draft.externalProduction
        ? 'Travail externe validé : le stock a été mis à jour et la machine temporaire supprimée.'
        : 'Production validée et ajoutée au stock.');
  }

  Future<void> updateOperationDraft(Operation draft) async {
    if (!widget.user.canValidate || !widget.user.canWritePage(AppPage.validation)) return forbidden('Vous n’avez pas le droit de modifier ce brouillon.');
    await widget.database.updateOperation(draft);
    if (mounted) setState(() {});
  }

  Future<void> cancelOperationDraft(Operation draft) async {
    if (!widget.user.canValidate || !widget.user.canWritePage(AppPage.validation)) return forbidden('Vous n’avez pas le droit d’annuler cette production.');
    await widget.database.deleteOperation(draft.id);
    if (draft.externalProduction) await widget.database.deleteMachine(draft.machineId);
    if (mounted) {
      setState(() {
        operations.removeWhere((item) => item.id == draft.id);
        if (draft.externalProduction) {
          machines.removeWhere((item) => item.id == draft.machineId);
        }
      });
    }
  }

  Future<void> cancelStockTransfer(StockTransfer draft) async {
    if (!widget.user.canValidate || !widget.user.canWritePage(AppPage.validation)) return forbidden('Vous n’avez pas le droit d’annuler ce transfert.');
    await widget.database.deleteStockTransfer(draft.id);
    if (mounted) setState(() => stockTransfers.removeWhere((item) => item.id == draft.id));
  }

  Future<void> addOperatorPayment(String operatorId, double amount) async {
    final payment = OperatorPayment(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      operatorId: operatorId,
      amount: amount,
      paidAt: DateTime.now(),
    );
    await widget.database.insertOperatorPayment(payment);
    if (mounted) setState(() => payments = [payment, ...payments]);
  }

  Future<void> changeMeterRate(double rate) async {
    if (rate <= 0) return;
    await widget.database.setMeterRate(rate);
    if (mounted) setState(() => meterRate = rate);
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final visibleOperations = widget.user.isAdmin
        ? operations
        : operations.where((operation) => operation.operatorId == widget.user.id).toList();
    if (widget.user.isOperator && widget.user.allowedPages.length == 1 && widget.user.allowedPages.contains(AppPage.machines)) {
      return Scaffold(
        body: Aura(
          child: SafeArea(
            child: Column(
              children: [
                AppHeader(
                  title: 'Machines',
                  user: widget.user,
                  onLogout: widget.onLogout,
                  onOpenTeam: () {},
                  onOpenBackups: () {},
                  onOpenAnalytics: () => _openAnalytics(context),
                  canAccessAnalytics: widget.user.canAccess(AppPage.analytics),
                ),
                Expanded(child: MachinesPage(
                  machines: machines,
                  operations: visibleOperations,
                  user: widget.user,
                  userName: (id) => appUser(id)?.fullName ?? '—',
                  categoryName: (id) => category(id)?.name ?? 'Sans catégorie',
                  productName: (id) => product(id)?.name ?? 'Produit introuvable',
                  hasActive: hasMyActiveOperation,
                  onAdd: addMachine,
                  onStart: start,
                  onFinish: finish,
                  onManage: manageMachine,
                  pendingReviews: 0,
                  onOpenReviews: () {},
                  showReviews: false,
                )),
              ],
            ),
          ),
        ),
      );
    }
    if (widget.user.canValidate && widget.user.allowedPages.length == 1 && widget.user.allowedPages.contains(AppPage.validation)) {
      return Scaffold(
        body: Aura(
          child: SafeArea(
            child: Column(
              children: [
                AppHeader(
                  title: 'Validations',
                  user: widget.user,
                  onLogout: widget.onLogout,
                  onOpenTeam: () {},
                  onOpenBackups: () {},
                  onOpenAnalytics: () => _openAnalytics(context),
                  canAccessAnalytics: widget.user.canAccess(AppPage.analytics),
                ),
                Expanded(
                  child: ValidationPage(
                    products: products,
                    depots: depots,
                    stockDrafts: stockAdditions.where((item) => item.draft).toList(),
                    saleDrafts: sales.where((item) => item.draft).toList(),
                    returnDrafts: saleReturns.where((item) => item.status == ReturnValidationStatus.pending).toList(),
                    operationDrafts: operations.where((item) => !item.active && item.completionDraft).toList(),
                    transferDrafts: stockTransfers.where((item) => item.draft).toList(),
                    onApproveStock: approveStockDraft,
                    onEditStock: updateStockDraft,
                    onCancelStock: cancelStockDraft,
                    onApproveSale: approveSaleDraft,
                    onEditSale: updateSaleDraft,
                    onCancelSale: cancelSaleDraft,
                    onApproveReturn: approveSaleReturn,
                    onEditReturn: updateSaleReturn,
                    onRejectReturn: rejectSaleReturn,
                    onCancelReturn: cancelSaleReturn,
                    onApproveOperation: approveOperationDraft,
                    onEditOperation: updateOperationDraft,
                    onCancelOperation: cancelOperationDraft,
                    onApproveTransfer: approveStockTransfer,
                    onCancelTransfer: cancelStockTransfer,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    final pages = [
      DashboardPage(
        user: widget.user,
        productCount: products.length,
        machineCount: machines.length,
        pendingReviews: operations.where((op) => op.needsReview).length,
        onProducts: () => setState(() => section = 1),
        onStock: () => setState(() => section = 2),
        onMachines: () => setState(() => section = 3),
        onTeam: () => setState(() => section = 4),
        onValidation: () => setState(() => section = 5),
        onCategories: () => _openCategories(context),
        onReviews: () => _openReviews(context),
      ),
      ProductsPage(
        products: products,
        categories: categories,
        stock: stock,
        depots: depots,
        depotStock: depotStock,
        canEdit: widget.user.canWritePage(AppPage.products),
        onAdd: addProduct,
        onAddStock: addStockFor,
        onOpenCategories: () => _openCategories(context),
      ),
      StockPage(
        products: products,
        stock: stock,
        draftCount:
            stockAdditions.where((item) => item.draft).length +
            sales.where((item) => item.draft).length +
            saleReturns
                .where((item) => item.status == ReturnValidationStatus.pending)
                .length +
            stockTransfers.where((item) => item.draft).length,
        canEdit: widget.user.canWritePage(AppPage.stock),
        onPurchase: addStock,
        onSale: addSale,
        onOpenDepots: () => _openDepots(context),
        onOpenRecords: openStockRecords,
      ),
      MachinesPage(
        machines: machines,
        operations: visibleOperations,
        user: widget.user,
        userName: (id) => appUser(id)?.fullName ?? '—',
        categoryName: (id) => category(id)?.name ?? 'Sans catégorie',
        productName: (id) => product(id)?.name ?? 'Produit introuvable',
        hasActive: hasMyActiveOperation,
        onAdd: addMachine,
        onStart: start,
        onFinish: finish,
        onManage: manageMachine,
        pendingReviews: operations.where((op) => op.needsReview).length,
        onOpenReviews: () => _openReviews(context),
      ),
      UsersPage(
        users: widget.user.isAdmin ? widget.users : [widget.user],
        admin: widget.user.isAdmin,
        onAdd: widget.onUserAdded,
        onUpdate: widget.onUserUpdated,
        onLoadSessions: widget.database.loadUserSessions,
        onOpenPayroll: () => _openPayroll(context),
      ),
      ValidationPage(
        products: products,
        depots: depots,
        stockDrafts: stockAdditions.where((item) => item.draft).toList(),
        saleDrafts: sales.where((item) => item.draft).toList(),
        returnDrafts: saleReturns.where((item) => item.status == ReturnValidationStatus.pending).toList(),
        operationDrafts: operations.where((item) => !item.active && item.completionDraft).toList(),
        transferDrafts: stockTransfers.where((item) => item.draft).toList(),
        onApproveStock: approveStockDraft,
        onEditStock: updateStockDraft,
        onCancelStock: cancelStockDraft,
        onApproveSale: approveSaleDraft,
        onEditSale: updateSaleDraft,
        onCancelSale: cancelSaleDraft,
        onApproveReturn: approveSaleReturn,
        onEditReturn: updateSaleReturn,
        onRejectReturn: rejectSaleReturn,
        onCancelReturn: cancelSaleReturn,
        onApproveOperation: approveOperationDraft,
        onEditOperation: updateOperationDraft,
        onCancelOperation: cancelOperationDraft,
        onApproveTransfer: approveStockTransfer,
        onCancelTransfer: cancelStockTransfer,
      ),
    ];
    final pageKeys = [
      AppPage.dashboard, AppPage.products, AppPage.stock, AppPage.machines,
      AppPage.team, AppPage.validation,
    ];
    final titles = ['Accueil', 'Produits', 'Stock', 'Machines', 'Équipe', 'Validations'];
    return Scaffold(
      extendBody: true,
      body: Aura(
        child: SafeArea(
          child: Column(
            children: [
              AppHeader(
                title: titles[section],
                user: widget.user,
                onLogout: widget.onLogout,
                onOpenTeam: () => setState(() => section = 4),
                onOpenBackups: () => _openBackups(context),
                onOpenAnalytics: () => _openAnalytics(context),
                canAccessAnalytics: widget.user.canAccess(AppPage.analytics),
                onOpenDeveloper: () => _openDeveloper(context),
              ),
              Expanded(
                child: widget.user.canAccess(pageKeys[section])
                    ? pages[section]
                    : _PageAccessDenied(page: pageKeys[section]),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: MobileGlassNavigation(
        index: section,
        onTap: (value) => setState(() => section = value),
      ),
    );
  }

  Future<void> _openCategories(BuildContext context) => Navigator.push<void>(
    context,
    MaterialPageRoute(
      builder: (_) => ManagementScreen(
        title: 'Catégories',
        child: CategoriesPage(
          categories: categories,
          products: products,
          admin: widget.user.isAdmin,
          onAdd: addCategory,
          onEdit: editCategory,
        ),
      ),
    ),
  );

  Future<void> _openDepots(BuildContext context) => Navigator.push<void>(
    context,
    MaterialPageRoute(
      builder: (_) => ManagementScreen(
        title: 'Dépôts',
        child: DepotsPage(
          depots: depots,
          products: products,
          stock: depotStock,
          canEdit: widget.user.canWritePage(AppPage.stock),
          canTransfer: widget.user.isAdmin,
          onAdd: addDepot,
          onTransfer: createStockTransfer,
        ),
      ),
    ),
  );

  Future<void> _openReviews(BuildContext context) => Navigator.push<void>(
    context,
    MaterialPageRoute(
      builder: (_) => ManagementScreen(
        title: 'Contrôles',
        child: ReviewsPage(
          operations: operations.where((op) => op.needsReview).toList(),
          product: product,
          userName: (id) => appUser(id)?.fullName ?? '—',
          depots: depots,
          admin: widget.user.isAdmin,
          onApprove: approveReview,
        ),
      ),
    ),
  );

  Future<void> _openBackups(BuildContext context) => Navigator.push<void>(
    context,
    MaterialPageRoute(
      builder: (_) => BackupPage(
        lastBackupAt: widget.database.lastBackupAt,
        onDownload: () => _downloadBackup(),
        onRestore: _restoreBackup,
        onClearData: _clearWorkshopData,
      ),
    ),
  );

  Future<void> _openAnalytics(BuildContext context) {
    if (!widget.user.canAccess(AppPage.analytics)) {
      forbidden('Vous n’avez pas le droit d’accéder aux analyses.');
      return Future<void>.value();
    }
    return Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => AnalyticsPage(
          products: products,
          operations: operations,
          sales: sales,
          purchases: stockAdditions,
          stock: stock,
        ),
      ),
    );
  }

  Future<void> _openDeveloper(BuildContext context) {
    if (!widget.user.isDeveloper) return Future<void>.value();
    return Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => DeveloperModePage(
          products: products,
          categories: categories,
          depots: depots,
          purchases: stockAdditions,
          sales: sales,
          machines: machines,
          operations: operations,
          transfers: stockTransfers,
          returns: saleReturns,
          database: widget.database,
          onChanged: loadWorkshop,
        ),
      ),
    );
  }

  Future<void> _openPayroll(BuildContext context) => Navigator.push<void>(
    context,
    MaterialPageRoute(
      builder: (_) => ManagementScreen(
        title: 'Paiements des opérateurs',
        child: PayrollPage(
          users: widget.users,
          products: products,
          operations: operations,
          payments: payments,
          meterRate: meterRate,
          onPay: addOperatorPayment,
          onRateChanged: changeMeterRate,
        ),
      ),
    ),
  );
}

class Aura extends StatelessWidget {
  const Aura({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      const DecoratedBox(decoration: BoxDecoration(color: AppPalette.background)),
      const Positioned(
        top: -165,
        left: -95,
        child: Glow(size: 390, color: Color(0xFF758EF1)),
      ),
      const Positioned(
        top: -125,
        right: -135,
        child: Glow(size: 360, color: Color(0xFFC681EB)),
      ),
      const Positioned(
        top: 0,
        left: 0,
        right: 0,
        child: SizedBox(
          height: 145,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF647EE5), Color(0xFFA373E3)],
              ),
              borderRadius: BorderRadius.vertical(bottom: Radius.circular(38)),
            ),
          ),
        ),
      ),
      child,
    ],
  );
}

class _PageAccessDenied extends StatelessWidget {
  const _PageAccessDenied({required this.page});
  final AppPage page;
  @override
  Widget build(BuildContext context) => Center(
    child: Glass(
      padding: const EdgeInsets.all(24),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.lock_outline_rounded, size: 42, color: AppPalette.primary),
        const SizedBox(height: 12),
        Text('Accès à « ${page.label} » non autorisé', style: const TextStyle(fontWeight: FontWeight.w900)),
        const SizedBox(height: 6),
        const Text('Demandez au responsable de modifier vos droits.', textAlign: TextAlign.center, style: TextStyle(color: AppPalette.muted)),
      ]),
    ),
  );
}

class Glow extends StatelessWidget {
  const Glow({super.key, required this.size, required this.color});
  final double size;
  final Color color;
  @override
  Widget build(BuildContext context) => ImageFiltered(
    imageFilter: ImageFilter.blur(sigmaX: 55, sigmaY: 55),
    child: Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    ),
  );
}

class Glass extends StatelessWidget {
  const Glass({super.key, required this.child, this.padding});
  final Widget child;
  final EdgeInsets? padding;
  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(24),
    child: BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 13, sigmaY: 13),
      child: Container(
        padding: padding,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: .86),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.white.withValues(alpha: .92)),
          boxShadow: const [
            BoxShadow(color: Color(0x180B1230), blurRadius: 28, offset: Offset(0, 12)),
          ],
        ),
        child: child,
      ),
    ),
  );
}

class AppHeader extends StatelessWidget {
  const AppHeader({
    super.key,
    required this.title,
    required this.user,
    required this.onLogout,
    required this.onOpenTeam,
    required this.onOpenBackups,
    required this.onOpenAnalytics,
    required this.canAccessAnalytics,
    this.onOpenDeveloper,
  });
  final String title;
  final AppUser user;
  final VoidCallback onLogout;
  final VoidCallback onOpenTeam;
  final VoidCallback onOpenBackups;
  final VoidCallback onOpenAnalytics;
  final bool canAccessAnalytics;
  final VoidCallback? onOpenDeveloper;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(22, 16, 22, 20),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w900,
                  color: Colors.white,
                ),
              ),
              Text(
                user.effectiveRole.label,
                style: const TextStyle(
                  color: Color(0xFFF3EEFF),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        if (canAccessAnalytics) ...[
          Tooltip(
            message: 'Analyses',
            child: IconButton(
              onPressed: onOpenAnalytics,
              icon: const Icon(Icons.query_stats_rounded),
              color: Colors.white,
              style: IconButton.styleFrom(
                backgroundColor: Colors.white.withValues(alpha: .20),
                side: BorderSide(color: Colors.white.withValues(alpha: .32)),
              ),
            ),
          ),
          const SizedBox(width: 8),
        ],
        if (user.isDeveloper && onOpenDeveloper != null) ...[
          Tooltip(
            message: 'Mode développeur',
            child: IconButton(
              onPressed: onOpenDeveloper,
              icon: const Icon(Icons.admin_panel_settings_rounded),
              color: Colors.white,
              style: IconButton.styleFrom(
                backgroundColor: const Color(0xFFDC2626),
                side: const BorderSide(color: Color(0xFFFCA5A5)),
              ),
            ),
          ),
          const SizedBox(width: 8),
        ],
        InkWell(
          onTap: () => showModalBottomSheet<void>(
            context: context,
            backgroundColor: Colors.transparent,
            builder: (_) => ProfileSheet(
              user: user,
              onOpenTeam: () {
                Navigator.pop(context);
                onOpenTeam();
              },
              onOpenBackups: () {
                Navigator.pop(context);
                onOpenBackups();
              },
              onLogout: () {
                Navigator.pop(context);
                onLogout();
              },
            ),
          ),
          borderRadius: BorderRadius.circular(28),
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: .23),
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: Colors.white.withValues(alpha: .32)),
            ),
            child: CircleAvatar(
              backgroundColor: Colors.white,
              foregroundColor: AppPalette.primary,
              child: Text(user.fullName.substring(0, 1).toUpperCase()),
            ),
          ),
        ),
      ],
    ),
  );
}

class ProfileSheet extends StatelessWidget {
  const ProfileSheet({
    super.key,
    required this.user,
    required this.onOpenTeam,
    required this.onOpenBackups,
    required this.onLogout,
  });
  final AppUser user;
  final VoidCallback onOpenTeam;
  final VoidCallback onOpenBackups;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: TweenAnimationBuilder<double>(
      duration: const Duration(milliseconds: 340),
      curve: Curves.easeOutCubic,
      tween: Tween(begin: 0, end: 1),
      builder: (context, value, child) => Transform.translate(
        offset: Offset(0, 28 * (1 - value)),
        child: Opacity(opacity: value, child: child),
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
          child: Container(
            padding: const EdgeInsets.fromLTRB(22, 12, 22, 22),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: .68),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
              border: Border.all(color: Colors.white.withValues(alpha: .8)),
            ),
            child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 44,
            height: 5,
            decoration: BoxDecoration(
              color: const Color(0xFFD9D6F8),
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          const SizedBox(height: 22),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [AppPalette.primaryDark, AppPalette.primary],
              ),
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                  color: AppPalette.primary.withValues(alpha: .22),
                  blurRadius: 22,
                  offset: const Offset(0, 9),
                ),
              ],
            ),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 29,
                  backgroundColor: Colors.white.withValues(alpha: .22),
                  foregroundColor: Colors.white,
                  child: Text(
                    user.fullName.substring(0, 1).toUpperCase(),
                    style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(user.fullName, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w900)),
                      const SizedBox(height: 3),
                      Text('@${user.username}', style: const TextStyle(color: Color(0xFFF3E8FF))),
                      const SizedBox(height: 8),
                      Text(user.effectiveRole.label, style: const TextStyle(color: Color(0xFFF3E8FF), fontWeight: FontWeight.w800)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          ListTile(
            onTap: onOpenTeam,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
            tileColor: Colors.white.withValues(alpha: .46),
            leading: const Icon(Icons.groups_rounded, color: AppPalette.primary),
            title: const Text('Mon équipe', style: TextStyle(fontWeight: FontWeight.w800)),
            subtitle: const Text('Voir les membres de l’atelier'),
            trailing: const Icon(Icons.chevron_right_rounded),
          ),
          const SizedBox(height: 8),
           if (user.isAdmin) ...[
             ListTile(
               onTap: onOpenBackups,
               shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
               tileColor: Colors.white.withValues(alpha: .46),
               leading: const Icon(Icons.backup_rounded, color: AppPalette.primary),
               title: const Text('Sauvegardes', style: TextStyle(fontWeight: FontWeight.w800)),
               subtitle: const Text('Télécharger, restaurer ou supprimer les données'),
               trailing: const Icon(Icons.chevron_right_rounded),
             ),
             const SizedBox(height: 8),
           ],
          ListTile(
            onTap: onLogout,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
            leading: const Icon(Icons.logout_rounded, color: Color(0xFF9F1239)),
            title: const Text('Se déconnecter', style: TextStyle(color: Color(0xFF9F1239), fontWeight: FontWeight.w800)),
          ),
        ],
            ),
          ),
        ),
      ),
    ),
  );
}

class BackupPage extends StatefulWidget {
  const BackupPage({
    super.key,
    required this.lastBackupAt,
    required this.onDownload,
    required this.onRestore,
    required this.onClearData,
  });

  final Future<DateTime?> Function() lastBackupAt;
  final Future<bool> Function() onDownload;
  final Future<void> Function() onRestore;
  final Future<bool> Function() onClearData;

  @override
  State<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<BackupPage> {
  DateTime? lastBackup;
  var loading = true;
  var busy = false;

  bool get hasRecentBackup =>
      lastBackup != null && DateTime.now().difference(lastBackup!).inDays < 5;

  @override
  void initState() {
    super.initState();
    _refreshBackupStatus();
  }

  Future<void> _refreshBackupStatus() async {
    final value = await widget.lastBackupAt();
    if (mounted) {
      setState(() {
        lastBackup = value;
        loading = false;
      });
    }
  }

  Future<void> _download() async {
    setState(() => busy = true);
    await widget.onDownload();
    await _refreshBackupStatus();
    if (mounted) setState(() => busy = false);
  }

  Future<bool> _confirm({
    required String title,
    required String detail,
    required String action,
    required Color color,
  }) async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(title),
            content: Text(detail),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Annuler'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: color),
                onPressed: () => Navigator.pop(context, true),
                child: Text(action),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _restore() async {
    final confirmed = await _confirm(
      title: 'Restaurer la sauvegarde ?',
      detail:
          'Les données actuelles de l’atelier seront remplacées par celles du fichier choisi.',
      action: 'Importer',
      color: AppPalette.primary,
    );
    if (!confirmed || !mounted) return;
    setState(() => busy = true);
    await widget.onRestore();
    await _refreshBackupStatus();
    if (mounted) setState(() => busy = false);
  }

  Future<void> _clearData() async {
    final confirmed = await _confirm(
      title: 'Supprimer les données de l’atelier ?',
      detail:
          'Cette action supprimera les produits, catégories, machines, opérations, dépôts et ajouts de stock. Les comptes utilisateurs seront conservés.',
      action: 'Supprimer',
      color: const Color(0xFFB91C1C),
    );
    if (!confirmed || !mounted) return;
    setState(() => busy = true);
    await widget.onClearData();
    await _refreshBackupStatus();
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) => FormShell(
    title: 'Sauvegardes',
    subtitle: 'Protection des données de FORAGE ZOUHOUR',
    child: loading
        ? const Center(child: Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator()))
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Glass(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        color: hasRecentBackup
                            ? const Color(0xFFDCFCE7)
                            : const Color(0xFFFFEDD5),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        hasRecentBackup
                            ? Icons.verified_user_rounded
                            : Icons.warning_amber_rounded,
                        color: hasRecentBackup
                            ? const Color(0xFF15803D)
                            : const Color(0xFFB45309),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            hasRecentBackup
                                ? 'Sauvegarde automatique à jour'
                                : 'Sauvegarde à effectuer',
                            style: const TextStyle(fontWeight: FontWeight.w900),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            lastBackup == null
                                ? 'Aucune sauvegarde n’a encore été téléchargée.'
                                : 'Dernier téléchargement : ${dateText(lastBackup!)}',
                            style: const TextStyle(color: AppPalette.muted),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              const Glass(
                padding: EdgeInsets.all(14),
                child: Row(children: [
                  Icon(Icons.lock_outline_rounded, color: AppPalette.primary),
                  SizedBox(width: 10),
                  Expanded(child: Text(
                    'Les sauvegardes automatiques sont volontairement désactivées : '
                    'chaque sauvegarde est chiffrée avec un mot de passe que '
                    'l’application ne conserve pas.',
                    style: TextStyle(fontSize: 12, color: AppPalette.muted),
                  )),
                ]),
              ),
              const SizedBox(height: 10),
              const Text(
                'Télécharger une sauvegarde',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 6),
              const Text(
                'Enregistre un fichier JSON complet que vous pourrez conserver et réimporter plus tard.',
                style: TextStyle(color: AppPalette.muted),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: busy ? null : _download,
                  icon: const Icon(Icons.download_rounded),
                  label: const Text('Télécharger la sauvegarde'),
                ),
              ),
              const SizedBox(height: 22),
              const Text(
                'Restaurer une sauvegarde',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 6),
              const Text(
                'Importez un fichier de sauvegarde FORAGE ZOUHOUR pour remplacer les données actuelles.',
                style: TextStyle(color: AppPalette.muted),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: busy ? null : _restore,
                  icon: const Icon(Icons.upload_file_rounded),
                  label: const Text('Importer une sauvegarde'),
                ),
              ),
              const SizedBox(height: 22),
              const Text(
                'Zone sensible',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: Color(0xFF991B1B)),
              ),
              const SizedBox(height: 6),
              Text(
                hasRecentBackup
                    ? 'Une sauvegarde récente a été téléchargée : vous pouvez supprimer les informations de l’atelier.'
                    : 'La suppression reste bloquée tant qu’une nouvelle sauvegarde n’a pas été téléchargée.',
                style: const TextStyle(color: AppPalette.muted),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: const Color(0xFFB91C1C)),
                  onPressed: busy || !hasRecentBackup ? null : _clearData,
                  icon: const Icon(Icons.delete_forever_rounded),
                  label: const Text('Supprimer les données de l’atelier'),
                ),
              ),
            ],
          ),
  );
}

class DashboardPage extends StatelessWidget {
  const DashboardPage({
    super.key,
    required this.user,
    required this.productCount,
    required this.machineCount,
    required this.pendingReviews,
    required this.onProducts,
    required this.onStock,
    required this.onMachines,
    required this.onTeam,
    required this.onValidation,
    required this.onCategories,
    required this.onReviews,
  });

  final AppUser user;
  final int productCount;
  final int machineCount;
  final int pendingReviews;
  final VoidCallback onProducts;
  final VoidCallback onStock;
  final VoidCallback onMachines;
  final VoidCallback onTeam;
  final VoidCallback onValidation;
  final VoidCallback onCategories;
  final VoidCallback onReviews;

  @override
  Widget build(BuildContext context) => Page(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Bonjour, ${user.fullName.split(' ').first}', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
        const SizedBox(height: 5),
        const Text('Voici un aperçu de votre atelier.', style: TextStyle(color: AppPalette.muted)),
        const SizedBox(height: 20),
        Container(
          height: 205,
          width: double.infinity,
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF25186F), Color(0xFF1E78F2)]),
            borderRadius: BorderRadius.circular(22),
            boxShadow: const [BoxShadow(color: Color(0x382F24B8), blurRadius: 22, offset: Offset(0, 12))],
          ),
          child: Stack(
            children: [
              Positioned(right: -56, top: -70, child: Container(width: 190, height: 190, decoration: const BoxDecoration(color: Color(0x704FC2F4), shape: BoxShape.circle))),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('FORAGE ZOUHOUR', style: TextStyle(color: Color(0xFFD8E7FF), fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 1.1)),
                  const Spacer(),
                  Text('$machineCount machine${machineCount == 1 ? '' : 's'} active${machineCount == 1 ? '' : 's'}', style: const TextStyle(color: Colors.white, fontSize: 25, fontWeight: FontWeight.w900)),
                  const SizedBox(height: 8),
                  Text('$productCount produits · $pendingReviews contrôle${pendingReviews == 1 ? '' : 's'} en attente', style: const TextStyle(color: Color(0xFFE5F0FF), fontWeight: FontWeight.w700)),
                ],
              ),
              const Positioned(right: 0, bottom: 0, child: Icon(Icons.precision_manufacturing_rounded, color: Colors.white, size: 44)),
            ],
          ),
        ),
        const SizedBox(height: 24),
        const Text('Accès rapide', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
        const SizedBox(height: 12),
        GridView.count(
          crossAxisCount: 3,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: .92,
          children: [
            _DashboardAction(icon: Icons.inventory_2_outlined, color: const Color(0xFF3D2BC7), label: 'Produits', onTap: onProducts),
            _DashboardAction(icon: Icons.warehouse_outlined, color: const Color(0xFF0D8CE6), label: 'Stock', onTap: onStock),
            _DashboardAction(icon: Icons.precision_manufacturing_outlined, color: const Color(0xFFFF4D72), label: 'Machines', onTap: onMachines),
            _DashboardAction(icon: Icons.category_outlined, color: const Color(0xFFF59E0B), label: 'Catégories', onTap: onCategories),
            _DashboardAction(icon: user.canValidate ? Icons.verified_user_outlined : Icons.fact_check_outlined, color: const Color(0xFF14B8A6), label: user.canValidate ? 'Validations' : 'Contrôles', onTap: user.canValidate ? onValidation : onReviews),
            _DashboardAction(icon: Icons.groups_outlined, color: const Color(0xFF635BCE), label: 'Équipe', onTap: onTeam),
          ],
        ),
      ],
    ),
  );
}

class _DashboardAction extends StatelessWidget {
  const _DashboardAction({required this.icon, required this.color, required this.label, required this.onTap});
  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(22),
      child: Ink(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: .88),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: Colors.white),
          boxShadow: const [BoxShadow(color: Color(0x140E0B2A), blurRadius: 18, offset: Offset(0, 8))],
        ),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Container(
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(color: color.withValues(alpha: .13), shape: BoxShape.circle),
            child: Icon(icon, color: color, size: 23),
          ),
          const SizedBox(height: 10),
          Text(label, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, color: AppPalette.muted, fontWeight: FontWeight.w800)),
        ]),
      ),
    ),
  );
}

class MobileGlassNavigation extends StatelessWidget {
  const MobileGlassNavigation({
    super.key,
    required this.index,
    required this.onTap,
  });
  final int index;
  final ValueChanged<int> onTap;
  static const labels = [
    'Accueil', 'Produits', 'Stock', 'Machines', 'Équipe',
  ];
  static const icons = [
    Icons.home_rounded,
    Icons.grid_view_outlined,
    Icons.inventory_2_outlined,
    Icons.precision_manufacturing_outlined,
    Icons.people_outline,
  ];
  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(22),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: Container(
              height: 70,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: .78),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: Colors.white.withValues(alpha: .92)),
                boxShadow: const [BoxShadow(color: Color(0x180E0B2A), blurRadius: 18, offset: Offset(0, 5))],
              ),
              child: Row(
            children: List.generate(labels.length, (i) {
                  final selected = i == index;
                  return Expanded(
                    child: InkWell(
                      onTap: () => onTap(i),
                      borderRadius: BorderRadius.circular(20),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 240),
                            curve: Curves.easeOutCubic,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 13,
                              vertical: 5,
                            ),
                            decoration: BoxDecoration(
                              gradient: selected
                                  ? const LinearGradient(
                                      colors: [AppPalette.primaryDark, AppPalette.secondary],
                                    )
                                  : null,
                              color: selected ? null : Colors.transparent,
                              borderRadius: BorderRadius.circular(18),
                              boxShadow: selected
                                  ? [
                                      BoxShadow(
                                        color: AppPalette.primary.withValues(alpha: .26),
                                        blurRadius: 10,
                                        offset: const Offset(0, 4),
                                      ),
                                    ]
                                  : null,
                            ),
                            child: Icon(
                              icons[i],
                              color: selected ? Colors.white : AppPalette.muted,
                              size: 21,
                            ),
                          ),
                          const SizedBox(height: 2),
                          AnimatedDefaultTextStyle(
                            duration: const Duration(milliseconds: 200),
                            curve: Curves.easeOut,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: selected
                                  ? FontWeight.w900
                                  : FontWeight.w700,
                              color: selected ? AppPalette.primary : AppPalette.muted,
                            ),
                            child: Text(labels[i]),
                          ),
                        ],
                      ),
                    ),
                  );
                  }),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class Page extends StatelessWidget {
  const Page({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(22, 14, 22, 115),
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1050),
        child: AppEntrance(child: child),
      ),
    ),
  );
}

class SectionHero extends StatelessWidget {
  const SectionHero({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.trailing,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF7187EC), Color(0xFFAD79E4)],
      ),
      borderRadius: BorderRadius.circular(24),
      boxShadow: const [
        BoxShadow(color: Color(0x40726EE3), blurRadius: 24, offset: Offset(0, 12)),
      ],
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: .20),
            borderRadius: BorderRadius.circular(15),
          ),
          child: Icon(icon, color: Colors.white),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Colors.white)),
              const SizedBox(height: 4),
              Text(subtitle, style: const TextStyle(color: Color(0xFFF8F5FF), height: 1.35, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 8), trailing!],
      ],
    ),
  );
}

class ManagementScreen extends StatelessWidget {
  const ManagementScreen({super.key, required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.transparent,
    body: Aura(
      child: SafeArea(
        child: Column(
          children: [
            SizedBox(
              height: 126,
              child: Align(
                alignment: Alignment.topLeft,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 0, 0),
                  child: IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.arrow_back_rounded),
                    color: AppPalette.primary,
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.white,
                      shadowColor: Colors.black.withValues(alpha: .16),
                      elevation: 3,
                    ),
                    tooltip: 'Retour à $title',
                  ),
                ),
              ),
            ),
            Expanded(child: child),
          ],
        ),
      ),
    ),
  );
}

/// Animation partagée pour l'entrée douce des écrans et des nouveaux contenus.
class AppEntrance extends StatefulWidget {
  const AppEntrance({super.key, required this.child});
  final Widget child;
  @override
  State<AppEntrance> createState() => _AppEntranceState();
}

class _AppEntranceState extends State<AppEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
  )..forward();
  @override
  void dispose() { controller.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: CurvedAnimation(parent: controller, curve: Curves.easeOut),
    child: SlideTransition(
      position: Tween<Offset>(begin: const Offset(0, .025), end: Offset.zero)
          .animate(CurvedAnimation(parent: controller, curve: Curves.easeOutCubic)),
      child: widget.child,
    ),
  );
}

class Dashboard extends StatelessWidget {
  const Dashboard({
    super.key,
    required this.products,
    required this.depots,
    required this.operations,
    required this.stock,
  });
  final List<Product> products;
  final List<Depot> depots;
  final List<Operation> operations;
  final int Function(String) stock;
  @override
  Widget build(BuildContext context) => Page(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Glass(
          padding: const EdgeInsets.all(22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Votre atelier, en un seul regard',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 8),
              const Text(
                'Gérez les produits, le stock, les machines et les opérations en cours.',
              ),
              const SizedBox(height: 16),
              Text(
                '${operations.where((op) => op.active).length} opération(s) en cours',
                style: const TextStyle(
                  color: Color(0xFF7E22CE),
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        const Text(
          'Stock disponible',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: products
              .map(
                (p) => SizedBox(
                  width: 185,
                  child: Glass(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          p.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          productQuantityLabel(p, stock(p.id)),
                          style: const TextStyle(
                            fontSize: 21,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              )
              .toList(),
        ),
      ],
    ),
  );
}

class ProductsPage extends StatefulWidget {
  const ProductsPage({
    super.key,
    required this.products,
    required this.categories,
    required this.stock,
    required this.depots,
    required this.depotStock,
    required this.canEdit,
    required this.onAdd,
    required this.onAddStock,
    required this.onOpenCategories,
  });
  final List<Product> products;
  final List<ProductCategory> categories;
  final int Function(String) stock;
  final List<Depot> depots;
  final int Function(String, String) depotStock;
  final bool canEdit;
  final VoidCallback onAdd;
  final ValueChanged<Product> onAddStock;
  final VoidCallback onOpenCategories;
  @override
  State<ProductsPage> createState() => _ProductsPageState();
}

class _ProductsPageState extends State<ProductsPage> {
  final search = TextEditingController();
  String? categoryId;
  var showFilters = false;

  List<Product> get filteredProducts {
    final query = search.text.trim().toLowerCase();
    final allowed = categoryId == null
        ? null
        : widget.categories
            .where((category) => category.id == categoryId)
            .expand((category) => category.productIds)
            .toSet();
    return widget.products.where((product) {
      // Produced dimensions belong below their manufacturing template instead
      // of competing with the normal catalogue.
      return !product.isManufacturedVariant &&
          (query.isEmpty || product.name.toLowerCase().contains(query)) &&
          (allowed == null || allowed.contains(product.id));
    }).toList();
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Page(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHero(
          icon: Icons.inventory_2_rounded,
          title: 'Catalogue des produits',
          subtitle: '${widget.products.where((product) => !product.isManufacturedVariant).length} produits principaux organisés pour votre atelier.',
        ),
        const SizedBox(height: 16),
        const Text(
          'Gérer le catalogue',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            IconButton.filledTonal(
              onPressed: () => setState(() => showFilters = !showFilters),
              icon: Icon(showFilters ? Icons.filter_list_off : Icons.tune_rounded),
              tooltip: 'Filtres',
            ),
            const Spacer(),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: widget.onOpenCategories,
              icon: const Icon(Icons.category_outlined),
              label: const Text('Catégories'),
            ),
            const SizedBox(width: 6),
            IconButton.filledTonal(
              onPressed: () => PdfReports.printAllProducts(
                products: widget.products,
                depots: widget.depots,
                depotStock: widget.depotStock,
              ),
              icon: const Icon(Icons.print_outlined),
              tooltip: 'Imprimer tous les produits',
            ),
            const SizedBox(width: 6),
            if (widget.canEdit)
              IconButton.filled(
                onPressed: widget.onAdd,
                icon: const Icon(Icons.add),
                tooltip: 'Ajouter un produit',
              ),
          ],
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
          child: showFilters
              ? Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: Glass(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      children: [
                        TextField(
                          controller: search,
                          onChanged: (_) => setState(() {}),
                          decoration: const InputDecoration(
                            labelText: 'Filtrer par nom de produit',
                            prefixIcon: Icon(Icons.search_rounded),
                          ),
                        ),
                        const SizedBox(height: 10),
                        DropdownButtonFormField<String>(
                          initialValue: categoryId,
                          decoration: const InputDecoration(
                            labelText: 'Filtrer par catégorie',
                            prefixIcon: Icon(Icons.category_outlined),
                          ),
                          items: [
                            const DropdownMenuItem<String>(
                              value: null,
                              child: Text('Toutes les catégories'),
                            ),
                            ...widget.categories.map((category) => DropdownMenuItem(
                                  value: category.id,
                                  child: Text(category.name),
                                )),
                          ],
                          onChanged: (value) => setState(() => categoryId = value),
                        ),
                      ],
                    ),
                  ),
                )
              : const SizedBox.shrink(),
        ),
        const SizedBox(height: 16),
        if (widget.products.isEmpty)
          const Empty(
            icon: Icons.photo_library_outlined,
            title: 'Aucun produit',
            detail: 'Ajoutez votre premier produit.',
          )
        else if (filteredProducts.isEmpty)
          const Empty(
            icon: Icons.search_off_rounded,
            title: 'Aucun résultat',
            detail: 'Modifiez le nom ou la catégorie sélectionnée.',
          )
        else
          LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 400;
              const spacing = 12.0;
              final cardWidth = compact
                  ? (constraints.maxWidth - spacing) / 2
                  : 180.0;
              return Wrap(
                spacing: compact ? spacing : 14,
                runSpacing: compact ? spacing : 14,
                children: filteredProducts
                    .map(
                      (product) => SizedBox(
                        width: cardWidth,
                        child: ProductCard(
                          product: product,
                          onTap: () => Navigator.of(context).push(
                            PageRouteBuilder<void>(
                              pageBuilder:
                                  (context, animation, secondaryAnimation) =>
                                      ProductDetailsPage(
                                        product: product,
                                        stockPieces: widget.stock(product.id),
                                        allProducts: widget.products,
                                        stock: widget.stock,
                                        categories: widget.categories,
                                        depots: widget.depots,
                                        depotStock: widget.depotStock,
                                        canEdit: widget.canEdit,
                                        onAddStock: widget.onAddStock,
                                      ),
                              transitionsBuilder:
                                  (context, animation, secondaryAnimation, child) =>
                                      FadeTransition(
                                        opacity: animation,
                                        child: ScaleTransition(
                                          scale:
                                              Tween<double>(begin: .92, end: 1)
                                                  .animate(
                                                    CurvedAnimation(
                                                      parent: animation,
                                                      curve: Curves.easeOutCubic,
                                                    ),
                                                  ),
                                          child: child,
                                        ),
                                      ),
                            ),
                          ),
                        ),
                      ),
                    )
                    .toList(),
              );
            },
          ),
      ],
    ),
  );
}

class ProductCard extends StatelessWidget {
  const ProductCard({super.key, required this.product, required this.onTap});
  final Product product;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(28),
    child: Glass(
      padding: const EdgeInsets.all(10),
      child: AspectRatio(
        aspectRatio: .92,
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: Hero(
                  tag: 'product-image-${product.id}',
                  child: ProductImage(
                    product: product,
                    height: 124,
                    circular: true,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              product.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 3),
            Text(
              productSpecification(product),
              style: const TextStyle(color: Color(0xFF725280), fontSize: 12),
            ),
          ],
        ),
      ),
    ),
  );
}

class ProductImage extends StatelessWidget {
  const ProductImage({
    super.key,
    required this.product,
    required this.height,
    this.circular = false,
  });
  final Product product;
  final double height;
  final bool circular;
  @override
  Widget build(BuildContext context) {
    final image = SizedBox(
      height: height,
      width: circular ? height : double.infinity,
      child: product.image == null
          ? DecoratedBox(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFFCE93F9), Color(0xFF6B21A8)],
                ),
              ),
              child: const Icon(
                Icons.layers_rounded,
                color: Colors.white,
                size: 44,
              ),
            )
          : Image.memory(product.image!, fit: BoxFit.cover),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(circular ? height / 2 : 16),
      child: image,
    );
  }
}

class CategoryImage extends StatelessWidget {
  const CategoryImage({super.key, required this.category, required this.size});
  final ProductCategory category;
  final double size;
  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(14),
    child: SizedBox(
      width: size,
      height: size,
      child: category.image.isEmpty
          ? const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: [Color(0xFFDDD6FE), Color(0xFF7E22CE)]),
              ),
              child: Icon(Icons.category_rounded, color: Colors.white),
            )
          : Image.memory(category.image, fit: BoxFit.cover),
    ),
  );
}

class ProductDetailsPage extends StatelessWidget {
  const ProductDetailsPage({
    super.key,
    required this.product,
    required this.stockPieces,
    required this.allProducts,
    required this.stock,
    required this.categories,
    required this.depots,
    required this.depotStock,
    required this.canEdit,
    required this.onAddStock,
  });
  final Product product;
  final int stockPieces;
  final List<Product> allProducts;
  final int Function(String) stock;
  final List<ProductCategory> categories;
  final List<Depot> depots;
  final int Function(String, String) depotStock;
  final bool canEdit;
  final ValueChanged<Product> onAddStock;

  @override
  Widget build(BuildContext context) {
    final derivedProducts = allProducts
        .where((item) => item.parentProductId == product.id)
        .toList();
    // A template represents the sum of the sizes manufactured from it. Its
    // own row is only a recipe, so it must not inflate the displayed total.
    final displayedStock = derivedProducts.isEmpty
        ? stockPieces
        : derivedProducts.fold<int>(0, (total, item) => total + stock(item.id));
    final stockMeters = derivedProducts.isEmpty
        ? displayedStock * product.lengthMeters
        : derivedProducts.fold<double>(
            0, (total, item) => total + stock(item.id) * item.lengthMeters);
    final stockKilograms = derivedProducts.isEmpty
        ? displayedStock * product.kilogramsPerPiece
        : derivedProducts.fold<double>(
            0, (total, item) => total + stock(item.id) * item.kilogramsPerPiece);

    void openProduct(Product item) => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ProductDetailsPage(
              product: item,
              stockPieces: stock(item.id),
              allProducts: allProducts,
              stock: stock,
              categories: categories,
              depots: depots,
              depotStock: depotStock,
              canEdit: canEdit,
              onAddStock: onAddStock,
            ),
          ),
        );
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Aura(
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 12, 18, 8),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.arrow_back),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        product.name,
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    IconButton.filledTonal(
                      onPressed: () => PdfReports.printProductDetails(
                        product: product,
                        categories: categories,
                        depots: depots,
                        depotStock: depotStock,
                      ),
                      icon: const Icon(Icons.print_outlined),
                      tooltip: 'Imprimer la fiche produit',
                    ),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 42),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 620),
                      child: Glass(
                        padding: const EdgeInsets.all(22),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Center(
                              child: Hero(
                                tag: 'product-image-${product.id}',
                                child: ProductImage(
                                  product: product,
                                  height: 190,
                                  circular: true,
                                ),
                              ),
                            ),
                            const SizedBox(height: 20),
                            Text(
                              product.name,
                              style: const TextStyle(
                                fontSize: 26,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(product.kind.label, style: const TextStyle(color: Color(0xFF725280))),
                            if (product.reference.isNotEmpty) ...[
                              const SizedBox(height: 10),
                              _InfoRow(
                                icon: Icons.tag_rounded,
                                label: 'Référence',
                                value: product.reference,
                              ),
                            ],
                            const SizedBox(height: 10),
                            if (!product.isDiameterBased && !product.isHose)
                              _InfoRow(
                                icon: Icons.science_outlined,
                                label: 'Matière',
                                value: '${product.material.label} · ${formatNumber(product.material.density)} kg/m³',
                              ),
                            const SizedBox(height: 20),
                            if (product.isDiameterBased)
                              _InfoRow(
                                icon: Icons.architecture_outlined,
                                label: 'Diamètre',
                                value: 'Ø ${formatNumber(product.displayedDiameter ?? 0)} ${product.displayedDiameterUnit}',
                              )
                            else if (product.isHose)
                              const _InfoRow(
                                icon: Icons.water_drop_outlined,
                                label: 'Unité de vente',
                                value: 'Mètre',
                              )
                            else ...[
                              _InfoRow(
                                icon: Icons.straighten_rounded,
                                label: 'Longueur',
                                value:
                                    '${formatNumber(product.lengthInChosenUnit)} ${product.lengthUnit.label} (${formatNumber(product.lengthMeters)} m)',
                              ),
                              _InfoRow(
                                icon: Icons.layers_outlined,
                                label: 'Épaisseur',
                                value: '${formatNumber(product.thickness)} mm',
                              ),
                              if (product.displayedDiameter != null)
                                _InfoRow(
                                  icon: Icons.architecture_outlined,
                                  label: 'Diamètre calculé',
                                  value: 'Ø ${formatNumber(product.displayedDiameter!)} ${product.displayedDiameterUnit}',
                                ),
                              _InfoRow(
                                icon: Icons.view_week_outlined,
                                label: 'Largeur',
                                value: '${formatNumber(product.width)} m',
                              ),
                            ],
                            const Divider(height: 28),
                            const Text(
                              'Stock disponible',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            const SizedBox(height: 10),
                            _InfoRow(
                              icon: Icons.inventory_2_outlined,
                              label: 'Quantité',
                              value: productQuantityLabel(product, displayedStock),
                            ),
                            if (!product.isDiameterBased) ...[
                              _InfoRow(
                                icon: Icons.route_outlined,
                                label: 'Longueur totale',
                                value: '${formatNumber(stockMeters)} m',
                              ),
                              if (!product.isHose)
                                _InfoRow(
                                  icon: Icons.scale_outlined,
                                  label: 'Poids estimé',
                                  value: formatWeight(stockKilograms),
                                ),
                            ],
                            const SizedBox(height: 14),
                            const Text(
                              'Répartition par dépôt',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            const SizedBox(height: 8),
                            ...depots.map((depot) {
                              final pieces = derivedProducts.isEmpty
                                  ? depotStock(product.id, depot.id)
                                  : derivedProducts.fold<int>(0, (total, item) => total + depotStock(item.id, depot.id));
                              return _InfoRow(
                                icon: Icons.warehouse_outlined,
                                label: depot.name,
                                value: productQuantityLabel(product, pieces),
                              );
                            }),
                            if (derivedProducts.isNotEmpty) ...[
                              const SizedBox(height: 22),
                              Text(
                                'Produits dérivés (${derivedProducts.length})',
                                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
                              ),
                              const SizedBox(height: 6),
                              const Text(
                                'Ces dimensions ne figurent pas dans la liste générale. Leur stock est inclus dans le total ci-dessus.',
                                style: TextStyle(color: AppPalette.muted, fontSize: 12),
                              ),
                              const SizedBox(height: 10),
                              ...derivedProducts.map((item) => Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: _DerivedProductTile(
                                  product: item,
                                  pieces: stock(item.id),
                                  onTap: () => openProduct(item),
                                ),
                              )),
                            ],
                            const SizedBox(height: 18),
                            if (canEdit) SizedBox(
                              width: double.infinity,
                              child: FilledButton.icon(
                                onPressed: product.manufactured
                                    ? null
                                    : () {
                                        Navigator.pop(context);
                                        onAddStock(product);
                                      },
                                icon: const Icon(Icons.add_box_outlined),
                                label: Text(
                                  product.manufactured
                                      ? 'Ajout automatique par production'
                                      : 'Ajouter au stock',
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DerivedProductTile extends StatelessWidget {
  const _DerivedProductTile({
    required this.product,
    required this.pieces,
    required this.onTap,
  });
  final Product product;
  final int pieces;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Ink(
        padding: const EdgeInsets.all(9),
        decoration: BoxDecoration(
          color: const Color(0xFFF7F4FF),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFE4D9FF)),
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(width: 46, height: 46, child: ProductImage(product: product, height: 46)),
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(product.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800))),
            const SizedBox(width: 8),
            Text(productQuantityLabel(product, pieces), style: const TextStyle(color: Color(0xFF15803D), fontWeight: FontWeight.w900)),
            const Icon(Icons.chevron_right_rounded, color: AppPalette.muted),
          ],
        ),
      ),
    ),
  );
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });
  final IconData icon;
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: Row(
      children: [
        Icon(icon, color: const Color(0xFF7E22CE)),
        const SizedBox(width: 10),
        Expanded(child: Text(label)),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w900)),
      ],
    ),
  );
}

class StockAddition {
  const StockAddition({
    this.id,
    required this.productId,
    required this.depotId,
    required this.pieces,
    required this.receiptNumber,
    required this.quantity,
    required this.unit,
    required this.images,
    this.supplierId,
    required this.addedAt,
    this.draft = true,
  });
  final int? id;
  final String productId;
  final String depotId;
  final int pieces;
  final String receiptNumber;
  final String? supplierId;
  final double quantity;
  final InventoryUnit unit;
  final List<Uint8List> images;
  final DateTime addedAt;
  final bool draft;
}

class AnalyticsPage extends StatelessWidget {
  const AnalyticsPage({
    super.key,
    required this.products,
    required this.operations,
    required this.sales,
    required this.purchases,
    required this.stock,
  });

  final List<Product> products;
  final List<Operation> operations;
  final List<Sale> sales;
  final List<StockAddition> purchases;
  final int Function(String) stock;

  @override
  Widget build(BuildContext context) {
    final totalPieces = products.fold<int>(
      0,
      (total, product) => total + stock(product.id),
    );
    final available = products.where((product) => stock(product.id) > 0).length;
    final activeOperations = operations.where((operation) => operation.active).length;
    final produced = operations
        .where((operation) => !operation.active && !operation.completionDraft)
        .fold<int>(0, (total, operation) => total + (operation.outputPieces ?? 0));
    final sold = sales
        .where((sale) => !sale.draft)
        .fold<int>(0, (total, sale) => total + sale.pieces);
    final topProducts = [...products]
      ..sort((a, b) => stock(b.id).compareTo(stock(a.id)));

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Aura(
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 22, 16),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.arrow_back_rounded),
                      color: AppPalette.primary,
                      style: IconButton.styleFrom(backgroundColor: Colors.white),
                      tooltip: 'Retour',
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        'Analyses',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 23,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Page(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [Color(0xFF243B7A), Color(0xFF7B6BE3)],
                          ),
                          borderRadius: BorderRadius.circular(28),
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x3E4D63C8),
                              blurRadius: 26,
                              offset: Offset(0, 12),
                            ),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: .18),
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(
                                    Icons.insights_rounded,
                                    color: Colors.white,
                                  ),
                                ),
                                const Spacer(),
                                Text(
                                  '$available produits disponibles',
                                  style: const TextStyle(
                                    color: Color(0xFFE9E7FF),
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 18),
                            const Text(
                              'Vue d’ensemble de l’atelier',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 23,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            const SizedBox(height: 5),
                            Text(
                              '$totalPieces unités actuellement suivies dans le stock.',
                              style: const TextStyle(color: Color(0xFFE9E7FF)),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      LayoutBuilder(
                        builder: (context, constraints) {
                          const spacing = 12.0;
                          final metricWidth =
                              (constraints.maxWidth - spacing) / 2;
                          return Wrap(
                            spacing: spacing,
                            runSpacing: spacing,
                            children: [
                              _AnalyticsMetric(
                                width: metricWidth,
                                icon: Icons.inventory_2_rounded,
                                value: '$totalPieces',
                                label: 'Unités en stock',
                                color: AppPalette.primary,
                              ),
                              _AnalyticsMetric(
                                width: metricWidth,
                                icon: Icons.precision_manufacturing_rounded,
                                value: '$produced',
                                label: 'Unités produites',
                                color: AppPalette.mint,
                              ),
                              _AnalyticsMetric(
                                width: metricWidth,
                                icon: Icons.point_of_sale_rounded,
                                value: '$sold',
                                label: 'Unités vendues',
                                color: AppPalette.coral,
                              ),
                              _AnalyticsMetric(
                                width: metricWidth,
                                icon: Icons.play_circle_outline_rounded,
                                value: '$activeOperations',
                                label: 'Opérations en cours',
                                color: AppPalette.secondary,
                              ),
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: 22),
                      _PurchaseSaleChart(
                        purchases: purchases,
                        sales: sales,
                      ),
                      const SizedBox(height: 22),
                      const Text(
                        'Produits les plus disponibles',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
                      ),
                      const SizedBox(height: 10),
                      if (topProducts.isEmpty)
                        const Empty(
                          icon: Icons.bar_chart_rounded,
                          title: 'Pas encore de données',
                          detail: 'Ajoutez des produits et du stock pour voir les analyses.',
                        )
                      else
                        Glass(
                          child: Column(
                            children: topProducts.take(5).map((product) {
                              final quantity = stock(product.id);
                              return ListTile(
                                leading: ClipRRect(
                                  borderRadius: BorderRadius.circular(12),
                                  child: SizedBox(
                                    width: 42,
                                    height: 42,
                                    child: ProductImage(product: product, height: 42),
                                  ),
                                ),
                                title: Text(
                                  product.name,
                                  style: const TextStyle(fontWeight: FontWeight.w900),
                                ),
                                subtitle: Text(product.kind.label),
                                trailing: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 7,
                                  ),
                                  decoration: BoxDecoration(
                                    color: quantity > 0
                                        ? const Color(0xFFE8F8F4)
                                        : const Color(0xFFFFEDF0),
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  child: Text(
                                    productQuantityLabel(product, quantity),
                                    style: TextStyle(
                                      color: quantity > 0
                                          ? const Color(0xFF2A9B83)
                                          : const Color(0xFFD85B74),
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PurchaseSaleChart extends StatelessWidget {
  const _PurchaseSaleChart({required this.purchases, required this.sales});

  final List<StockAddition> purchases;
  final List<Sale> sales;

  static const _monthLabels = [
    'Jan', 'Fév', 'Mar', 'Avr', 'Mai', 'Juin',
    'Juil', 'Août', 'Sep', 'Oct', 'Nov', 'Déc',
  ];

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    final months = List.generate(
      6,
      (index) => DateTime(today.year, today.month - 5 + index),
    );
    final purchaseValues = months.map((month) => purchases
        .where((item) =>
            !item.draft &&
            item.addedAt.year == month.year &&
            item.addedAt.month == month.month)
        .fold<int>(0, (total, item) => total + item.pieces)).toList();
    final saleValues = months.map((month) => sales
        .where((item) =>
            !item.draft &&
            item.createdAt.year == month.year &&
            item.createdAt.month == month.month)
        .fold<int>(0, (total, item) => total + item.pieces)).toList();
    final purchasesTotal = purchaseValues.fold<int>(0, (total, value) => total + value);
    final salesTotal = saleValues.fold<int>(0, (total, value) => total + value);

    return Glass(
      padding: const EdgeInsets.fromLTRB(15, 15, 15, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Achats et ventes',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 3),
          const Text(
            'Comparaison mensuelle des unités validées — 6 derniers mois.',
            style: TextStyle(color: AppPalette.muted, fontSize: 12),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 16,
            runSpacing: 8,
            children: [
              _ChartLegend(
                color: const Color(0xFFFF5F7E),
                label: 'Achats · $purchasesTotal unités',
              ),
              _ChartLegend(
                color: const Color(0xFF25A97D),
                label: 'Ventes · $salesTotal unités',
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 210,
            width: double.infinity,
            child: CustomPaint(
              painter: _PurchaseSalePainter(
                purchaseValues: purchaseValues,
                saleValues: saleValues,
                labels: months.map((month) => _monthLabels[month.month - 1]).toList(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChartLegend extends StatelessWidget {
  const _ChartLegend({required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      const SizedBox(width: 6),
      Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
    ],
  );
}

class _PurchaseSalePainter extends CustomPainter {
  const _PurchaseSalePainter({
    required this.purchaseValues,
    required this.saleValues,
    required this.labels,
  });

  final List<int> purchaseValues;
  final List<int> saleValues;
  final List<String> labels;

  @override
  void paint(Canvas canvas, Size size) {
    const left = 7.0;
    const right = 7.0;
    const top = 10.0;
    const bottom = 28.0;
    final chartHeight = size.height - top - bottom;
    final baseline = size.height - bottom;
    final count = labels.length;
    final width = size.width - left - right;
    var highest = 0;
    for (final value in [...purchaseValues, ...saleValues]) {
      if (value > highest) highest = value;
    }
    final scale = highest == 0 ? 1.0 : highest.toDouble();

    final gridPaint = Paint()
      ..color = const Color(0xFFDBD8EC)
      ..strokeWidth = 1;
    for (var step = 0; step <= 4; step++) {
      final y = top + chartHeight * step / 4;
      canvas.drawLine(Offset(left, y), Offset(size.width - right, y), gridPaint);
    }
    if (highest == 0) {
      final text = TextPainter(
        text: const TextSpan(
          text: 'Aucun achat ou vente validé sur cette période',
          style: TextStyle(color: AppPalette.muted, fontSize: 12),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: size.width - 20);
      text.paint(canvas, Offset((size.width - text.width) / 2, top + chartHeight / 2 - text.height / 2));
    } else {
      _drawSeries(
        canvas: canvas,
        values: purchaseValues,
        color: const Color(0xFFFF5F7E),
        left: left,
        width: width,
        baseline: baseline,
        chartHeight: chartHeight,
        scale: scale,
      );
      _drawSeries(
        canvas: canvas,
        values: saleValues,
        color: const Color(0xFF25A97D),
        left: left,
        width: width,
        baseline: baseline,
        chartHeight: chartHeight,
        scale: scale,
      );
    }
    for (var index = 0; index < count; index++) {
      final x = count == 1 ? size.width / 2 : left + width * index / (count - 1);
      final text = TextPainter(
        text: TextSpan(
          text: labels[index],
          style: const TextStyle(color: AppPalette.muted, fontSize: 11, fontWeight: FontWeight.w700),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      text.paint(canvas, Offset(x - text.width / 2, baseline + 9));
    }
  }

  void _drawSeries({
    required Canvas canvas,
    required List<int> values,
    required Color color,
    required double left,
    required double width,
    required double baseline,
    required double chartHeight,
    required double scale,
  }) {
    Offset pointAt(int index) => Offset(
      values.length == 1 ? left + width / 2 : left + width * index / (values.length - 1),
      baseline - values[index] / scale * chartHeight,
    );
    final points = List.generate(values.length, pointAt);
    final area = Path()..moveTo(points.first.dx, baseline)..lineTo(points.first.dx, points.first.dy);
    final line = Path()..moveTo(points.first.dx, points.first.dy);
    for (var index = 1; index < points.length; index++) {
      final previous = points[index - 1];
      final current = points[index];
      final middleX = (previous.dx + current.dx) / 2;
      line.quadraticBezierTo(previous.dx, previous.dy, middleX, (previous.dy + current.dy) / 2);
      area.quadraticBezierTo(previous.dx, previous.dy, middleX, (previous.dy + current.dy) / 2);
    }
    line.lineTo(points.last.dx, points.last.dy);
    area
      ..lineTo(points.last.dx, points.last.dy)
      ..lineTo(points.last.dx, baseline)
      ..close();
    canvas.drawPath(area, Paint()..color = color.withValues(alpha: .16));
    canvas.drawPath(line, Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 3..strokeCap = StrokeCap.round..strokeJoin = StrokeJoin.round);
    final dotPaint = Paint()..color = color;
    for (final point in points) {
      canvas.drawCircle(point, 4.5, Paint()..color = Colors.white);
      canvas.drawCircle(point, 3, dotPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _PurchaseSalePainter oldDelegate) =>
      oldDelegate.purchaseValues != purchaseValues ||
      oldDelegate.saleValues != saleValues ||
      oldDelegate.labels != labels;
}

class _AnalyticsMetric extends StatelessWidget {
  const _AnalyticsMetric({
    required this.width,
    required this.icon,
    required this.value,
    required this.label,
    required this.color,
  });

  final double width;
  final IconData icon;
  final String value;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: Glass(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withValues(alpha: .14),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color),
          ),
          const SizedBox(height: 14),
          Text(value, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(color: AppPalette.muted, fontSize: 12)),
        ],
      ),
    ),
  );
}

class StockPage extends StatelessWidget {
  const StockPage({
    super.key,
    required this.products,
    required this.stock,
    required this.draftCount,
    required this.canEdit,
    required this.onPurchase,
    required this.onSale,
    required this.onOpenDepots,
    required this.onOpenRecords,
  });
  final List<Product> products;
  final int Function(String) stock;
  final int draftCount;
  final bool canEdit;
  final VoidCallback onPurchase;
  final VoidCallback onSale;
  final VoidCallback onOpenDepots;
  final VoidCallback onOpenRecords;
  @override
  Widget build(BuildContext context) {
    final availableProducts = products.where((product) => stock(product.id) > 0).length;
    final totalPieces = products.fold<int>(0, (total, product) => total + stock(product.id));

    return Page(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF667FE7), Color(0xFFAA79E5)],
              ),
              borderRadius: BorderRadius.circular(28),
              boxShadow: const [
                BoxShadow(color: Color(0x3C6D73E7), blurRadius: 28, offset: Offset(0, 14)),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: .20),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.inventory_2_rounded, color: Colors.white),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: .19),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.white.withValues(alpha: .22)),
                      ),
                      child: Text('$availableProducts disponibles', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 12)),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                const Text('Stock', style: TextStyle(color: Colors.white, fontSize: 27, fontWeight: FontWeight.w900)),
                const SizedBox(height: 4),
                Text('${products.length} produits suivis dans votre atelier', style: const TextStyle(color: Color(0xFFF7F3FF), fontWeight: FontWeight.w600)),
                const SizedBox(height: 18),
                Row(
                  children: [
                    _StockMetric(value: '$totalPieces', label: 'Unités en stock'),
                    Container(width: 1, height: 36, color: Colors.white.withValues(alpha: .25)),
                    _StockMetric(value: '$draftCount', label: 'En attente'),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          if (canEdit) ...[
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4),
              child: Text('Actions rapides', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _StockActionButton(
                    icon: Icons.add_shopping_cart_rounded,
                    title: 'Nouvel achat',
                    subtitle: 'Entrée de stock',
                    colors: const [Color(0xFF687DE7), Color(0xFF9C70E1)],
                    onTap: onPurchase,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _StockActionButton(
                    icon: Icons.point_of_sale_rounded,
                    title: 'Nouvelle vente',
                    subtitle: 'Sortie de stock',
                    colors: const [Color(0xFFFF839C), Color(0xFFFFAA7B)],
                    onTap: onSale,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
          ],
          Row(
            children: [
              Expanded(
                child: _StockSecondaryAction(
                  icon: Icons.warehouse_rounded,
                  label: 'Dépôts',
                  color: AppPalette.mint,
                  onTap: onOpenDepots,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _StockSecondaryAction(
                  icon: Icons.receipt_long_rounded,
                  label: 'Registres',
                  color: AppPalette.secondary,
                  onTap: onOpenRecords,
                ),
              ),
            ],
          ),
          if (draftCount > 0) ...[
            const SizedBox(height: 14),
            Glass(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: const BoxDecoration(color: Color(0xFFFFF1D7), shape: BoxShape.circle),
                    child: const Icon(Icons.edit_note_rounded, color: Color(0xFFF59E0B)),
                  ),
                  const SizedBox(width: 11),
                  Expanded(child: Text('$draftCount brouillon(s) attendent votre validation.', style: const TextStyle(fontWeight: FontWeight.w800))),
                ],
              ),
            ),
          ],
          const SizedBox(height: 20),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 4),
            child: Text('Disponibilité des produits', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
          ),
          const SizedBox(height: 10),
          ...products.map((product) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _StockProductTile(product: product, pieces: stock(product.id)),
          )),
        ],
      ),
    );
  }
}

class _StockActionButton extends StatelessWidget {
  const _StockActionButton({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.colors,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final List<Color> colors;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(22),
      child: Ink(
        height: 112,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: colors,
          ),
          borderRadius: BorderRadius.circular(22),
          boxShadow: [
            BoxShadow(
              color: colors.first.withValues(alpha: .28),
              blurRadius: 18,
              offset: const Offset(0, 9),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: .20),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: Colors.white, size: 20),
            ),
            const Spacer(),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              style: const TextStyle(color: Color(0xFFFDFBFF), fontSize: 11),
            ),
          ],
        ),
      ),
    ),
  );
}

class _StockMetric extends StatelessWidget {
  const _StockMetric({required this.value, required this.label});
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w900)),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(color: Color(0xFFF6F2FF), fontSize: 11, fontWeight: FontWeight.w600)),
        ],
      ),
    ),
  );
}

class _StockSecondaryAction extends StatelessWidget {
  const _StockSecondaryAction({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Ink(
        height: 66,
        padding: const EdgeInsets.symmetric(horizontal: 13),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: .83),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white),
          boxShadow: const [
            BoxShadow(color: Color(0x140E0B2A), blurRadius: 16, offset: Offset(0, 7)),
          ],
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: color.withValues(alpha: .16), shape: BoxShape.circle),
              child: Icon(icon, color: color, size: 20),
            ),
            const SizedBox(width: 9),
            Expanded(child: Text(label, style: const TextStyle(fontWeight: FontWeight.w900))),
            const Icon(Icons.chevron_right_rounded, color: AppPalette.muted),
          ],
        ),
      ),
    ),
  );
}

class _StockProductTile extends StatelessWidget {
  const _StockProductTile({required this.product, required this.pieces});
  final Product product;
  final int pieces;

  @override
  Widget build(BuildContext context) {
    final isEmpty = pieces <= 0;
    final subtitle = product.isHose
        ? productSpecification(product)
        : product.isDiameterBased
        ? productSpecification(product)
        : '${formatNumber(pieces * product.lengthMeters)} m · ${formatWeight(pieces * product.kilogramsPerPiece)}';

    return Glass(
      padding: const EdgeInsets.all(11),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: SizedBox(width: 58, height: 58, child: ProductImage(product: product, height: 58)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(product.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w900)),
                const SizedBox(height: 4),
                Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppPalette.muted, fontSize: 12)),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Container(
            constraints: const BoxConstraints(maxWidth: 82),
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
            decoration: BoxDecoration(
              color: isEmpty ? const Color(0xFFFFEDF0) : const Color(0xFFE8F8F4),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(
              productQuantityLabel(product, pieces),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: isEmpty ? const Color(0xFFD85B74) : const Color(0xFF2A9B83),
                fontSize: 11,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class StockRecordsPage extends StatefulWidget {
  const StockRecordsPage({
    super.key,
    required this.products,
    required this.additions,
    required this.sales,
    required this.saleReturns,
    required this.suppliers,
    required this.clients,
    required this.depotName,
    required this.canReturn,
    required this.onReturn,
  });

  final List<Product> products;
  final List<StockAddition> additions;
  final List<Sale> sales;
  final List<SaleReturn> saleReturns;
  final List<Supplier> suppliers;
  final List<Client> clients;
  final String Function(String) depotName;
  final bool canReturn;
  final Future<SaleReturn?> Function(Sale sale, int pieces) onReturn;

  @override
  State<StockRecordsPage> createState() => _StockRecordsPageState();
}

class _StockRecordsPageState extends State<StockRecordsPage> {
  bool purchasesSelected = true;
  late List<SaleReturn> saleReturns;

  @override
  void initState() {
    super.initState();
    saleReturns = [...widget.saleReturns];
  }

  Product? product(String id) {
    for (final item in widget.products) {
      if (item.id == id) return item;
    }
    return null;
  }

  Supplier? supplier(String? id) {
    for (final item in widget.suppliers) {
      if (item.id == id) return item;
    }
    return null;
  }

  Client? client(String id) {
    for (final item in widget.clients) {
      if (item.id == id) return item;
    }
    return null;
  }

  String supplierName(String? id) {
    final item = supplier(id);
    if (item == null) return 'Fournisseur non précisé';
    return item.company.isEmpty ? item.name : item.company;
  }

  String clientName(String id) {
    final item = client(id);
    if (item == null) return 'Client introuvable';
    return item.company.isEmpty ? item.name : item.company;
  }

  @override
  Widget build(BuildContext context) {
    final hasRecords = purchasesSelected
        ? widget.additions.isNotEmpty
        : widget.sales.isNotEmpty;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Aura(
        child: SafeArea(
          child: Column(
            children: [
              SizedBox(
                height: 122,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 22, 20),
                  child: Row(
                    children: [
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.arrow_back_rounded),
                        color: AppPalette.primary,
                        style: IconButton.styleFrom(backgroundColor: Colors.white),
                        tooltip: 'Retour',
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Registres du stock',
                              style: TextStyle(fontSize: 21, fontWeight: FontWeight.w900, color: Colors.white),
                            ),
                            SizedBox(height: 3),
                            Text(
                              'Consultez séparément les achats et les ventes.',
                              style: TextStyle(color: Color(0xFFE9E7FF)),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: Page(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: SegmentedButton<bool>(
                          segments: const [
                            ButtonSegment(
                              value: true,
                              icon: Icon(Icons.shopping_cart_checkout_rounded),
                              label: Text('Achats'),
                            ),
                            ButtonSegment(
                              value: false,
                              icon: Icon(Icons.point_of_sale_rounded),
                              label: Text('Ventes'),
                            ),
                          ],
                          selected: {purchasesSelected},
                          onSelectionChanged: (selection) =>
                              setState(() => purchasesSelected = selection.first),
                        ),
                      ),
                      const SizedBox(height: 18),
                      if (!hasRecords)
                        Empty(
                          icon: purchasesSelected
                              ? Icons.shopping_cart_outlined
                              : Icons.point_of_sale_outlined,
                          title: purchasesSelected
                              ? 'Aucun achat enregistré'
                              : 'Aucune vente enregistrée',
                          detail: purchasesSelected
                              ? 'Les prochains achats apparaîtront dans ce registre.'
                              : 'Les prochaines ventes apparaîtront dans ce registre.',
                        )
                      else
                        Glass(
                          child: Column(
                            children: purchasesSelected
                                ? widget.additions
                                    .map(_purchaseTile)
                                    .toList()
                                : widget.sales.map(_saleTile).toList(),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _purchaseTile(StockAddition addition) => ListTile(
    leading: const Icon(
      Icons.add_circle_outline_rounded,
      color: Color(0xFF7E22CE),
    ),
    title: Text(
      '+${formatQuantity(addition.quantity, addition.unit)} acheté',
      style: const TextStyle(fontWeight: FontWeight.w800),
    ),
    subtitle: Text(
      '${product(addition.productId)?.name ?? 'Produit'} · ${widget.depotName(addition.depotId)}\n${supplierName(addition.supplierId)} · ${addition.receiptNumber.isEmpty ? 'Sans n° de bon' : 'Bon n° ${addition.receiptNumber}'} · ${addition.addedAt.millisecondsSinceEpoch == 0 ? 'Ajout antérieur' : dateText(addition.addedAt)}',
    ),
    isThreeLine: true,
  );

  int returnedPieces(Sale sale) => saleReturns
      .where((item) =>
          item.saleId == sale.id &&
          item.status != ReturnValidationStatus.rejected)
      .fold(0, (total, item) => total + item.pieces);

  Future<void> _returnSale(Sale sale) async {
    final maximum = sale.pieces - returnedPieces(sale);
    if (maximum <= 0) return;
    final controller = TextEditingController();
    final selectedProduct = product(sale.productId);
    final pieces = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Retour client'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Maximum retournable : ${selectedProduct == null ? maximum : productQuantityLabel(selectedProduct, maximum)}.'),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(labelText: 'Quantité retournée *'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Annuler')),
          FilledButton(
            onPressed: () {
              final value = int.tryParse(controller.text);
              if (value == null || value <= 0 || value > maximum) return;
              Navigator.pop(dialogContext, value);
            },
            child: const Text('Envoyer à la validation'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (pieces == null) return;
    final returnRequest = await widget.onReturn(sale, pieces);
    if (mounted && returnRequest != null) {
      setState(() => saleReturns = [
        returnRequest,
        ...saleReturns,
      ]);
    }
  }

  Widget _saleTile(Sale sale) {
    final approved = saleReturns
        .where((item) => item.saleId == sale.id && item.status == ReturnValidationStatus.approved)
        .fold(0, (total, item) => total + item.pieces);
    final pending = saleReturns
        .where((item) => item.saleId == sale.id && item.status == ReturnValidationStatus.pending)
        .fold(0, (total, item) => total + item.pieces);
    final remaining = sale.pieces - approved - pending;
    final canReturnSale = widget.canReturn && !sale.draft && remaining > 0;
    return ListTile(
      leading: const Icon(
        Icons.remove_circle_outline_rounded,
        color: Color(0xFFB91C1C),
      ),
      title: Text(
        '-${formatQuantity(sale.quantity, sale.unit)} vendu',
        style: const TextStyle(fontWeight: FontWeight.w800),
      ),
      subtitle: Text(
        '${product(sale.productId)?.name ?? 'Produit'} · ${widget.depotName(sale.depotId)}\n${clientName(sale.clientId)} · ${dateText(sale.createdAt)}${approved > 0 ? '\nRetour validé : ${product(sale.productId) == null ? approved : productQuantityLabel(product(sale.productId)!, approved)}' : ''}${pending > 0 ? '\nRetour en attente : ${product(sale.productId) == null ? pending : productQuantityLabel(product(sale.productId)!, pending)}' : ''}',
      ),
      isThreeLine: approved > 0 || pending > 0,
      trailing: canReturnSale
          ? IconButton(
              tooltip: 'Retourner au stock',
              onPressed: () => _returnSale(sale),
              icon: const Icon(Icons.assignment_return_rounded, color: Color(0xFF15803D)),
            )
          : null,
    );
  }
}

class DepotsPage extends StatelessWidget {
  const DepotsPage({
    super.key,
    required this.depots,
    required this.products,
    required this.stock,
    required this.canEdit,
    required this.canTransfer,
    required this.onAdd,
    required this.onTransfer,
  });
  final List<Depot> depots;
  final List<Product> products;
  final int Function(String, String) stock;
  final bool canEdit;
  final bool canTransfer;
  final VoidCallback onAdd;
  final VoidCallback onTransfer;

  @override
  Widget build(BuildContext context) => Page(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHero(
          icon: Icons.warehouse_rounded,
          title: 'Dépôts',
          subtitle: 'Consultez les emplacements et le stock disponible.',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (canTransfer)
                IconButton.filledTonal(
                  onPressed: onTransfer,
                  icon: const Icon(Icons.swap_horiz_rounded),
                  tooltip: 'Transférer le stock',
                ),
              if (canTransfer && canEdit) const SizedBox(width: 8),
              if (canEdit)
                IconButton.filled(
                  onPressed: onAdd,
                  icon: const Icon(Icons.add),
                  tooltip: 'Ajouter un dépôt',
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (depots.isEmpty)
          const Empty(
            icon: Icons.warehouse_outlined,
            title: 'Aucun dépôt',
            detail: 'Ajoutez un dépôt avant de répartir le stock.',
          )
        else
          LayoutBuilder(
            builder: (context, constraints) => Wrap(
              spacing: 14,
              runSpacing: 14,
              children: depots.map((depot) {
              final pieces = products.fold(0, (total, product) =>
                  total + stock(product.id, depot.id));
              return SizedBox(
                width: constraints.maxWidth < 540 ? constraints.maxWidth : 250,
                child: InkWell(
                  borderRadius: BorderRadius.circular(24),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => DepotDetailsPage(
                        depot: depot,
                        products: products,
                        stock: stock,
                      ),
                    ),
                  ),
                  child: Glass(
                    padding: const EdgeInsets.all(14),
                    child: Row(
                      children: [
                        DepotImage(depot: depot, size: 62),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(depot.name, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
                              const SizedBox(height: 4),
                              Text('$pieces pièce(s)', style: const TextStyle(color: Color(0xFF725280))),
                            ],
                          ),
                        ),
                        Container(
                          width: 32,
                          height: 32,
                          decoration: const BoxDecoration(
                            color: AppPalette.soft,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.chevron_right_rounded, color: AppPalette.primary),
                        ),
                      ],
                    ),
                  ),
                ),
              );
              }).toList(),
            ),
          ),
      ],
    ),
  );
}

class DepotDetailsPage extends StatelessWidget {
  const DepotDetailsPage({
    super.key,
    required this.depot,
    required this.products,
    required this.stock,
  });
  final Depot depot;
  final List<Product> products;
  final int Function(String, String) stock;

  @override
  Widget build(BuildContext context) {
    final stored = products.where((product) => stock(product.id, depot.id) != 0).toList();
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Aura(
        child: SafeArea(
          child: Page(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.arrow_back),
                ),
                Glass(
                  child: Row(
                    children: [
                      DepotImage(depot: depot, size: 82),
                      const SizedBox(width: 14),
                      Expanded(child: Text(depot.name, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900))),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                const Text('Produits dans ce dépôt', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
                const SizedBox(height: 8),
                if (stored.isEmpty)
                  const Empty(
                    icon: Icons.inventory_2_outlined,
                    title: 'Aucun produit',
                    detail: 'Aucun stock n’est actuellement attribué à ce dépôt.',
                  )
                else
                  Glass(
                    child: Column(
                      children: stored.map((product) => ListTile(
                        leading: SizedBox(width: 48, child: ProductImage(product: product, height: 48)),
                        title: Text(product.name, style: const TextStyle(fontWeight: FontWeight.w800)),
                        subtitle: Text('${formatNumber(stock(product.id, depot.id) * product.lengthMeters)} m'),
                        trailing: Text('${stock(product.id, depot.id)} pièces', style: const TextStyle(fontWeight: FontWeight.w900)),
                      )).toList(),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class DepotImage extends StatelessWidget {
  const DepotImage({super.key, required this.depot, required this.size});
  final Depot depot;
  final double size;
  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(14),
    child: SizedBox(
      width: size,
      height: size,
      child: depot.image == null
          ? const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: [Color(0xFFDDD6FE), Color(0xFF6B21A8)]),
              ),
              child: Icon(Icons.warehouse_rounded, color: Colors.white),
            )
          : Image.memory(depot.image!, fit: BoxFit.cover),
    ),
  );
}

class MachinesPage extends StatelessWidget {
  const MachinesPage({
    super.key,
    required this.machines,
    required this.operations,
    required this.user,
    required this.userName,
    required this.categoryName,
    required this.productName,
    required this.hasActive,
    required this.onAdd,
    required this.onStart,
    required this.onFinish,
    required this.onManage,
    required this.pendingReviews,
    required this.onOpenReviews,
    this.showReviews = true,
  });
  final List<FactoryMachine> machines;
  final List<Operation> operations;
  final AppUser user;
  final String Function(String) userName;
  final String Function(String) categoryName;
  final String Function(String) productName;
  final bool hasActive;
  final VoidCallback onAdd;
  final void Function(FactoryMachine, MachineUnit) onStart;
  final ValueChanged<Operation> onFinish;
  final ValueChanged<FactoryMachine> onManage;
  final int pendingReviews;
  final VoidCallback onOpenReviews;
  final bool showReviews;
  @override
  Widget build(BuildContext context) => Page(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHero(
          icon: Icons.precision_manufacturing_rounded,
          title: 'Machines',
          subtitle: '${machines.where((machine) => !machine.temporary).fold<int>(0, (total, machine) => total + machine.copies)} exemplaire(s) · ${machines.where((machine) => machine.temporary).length} travail(s) externe(s) · ${operations.where((operation) => operation.active).length} opération(s) en cours',
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            const Spacer(),
            if (showReviews) Badge(
              isLabelVisible: pendingReviews > 0,
              label: Text('$pendingReviews'),
              child: Tooltip(
                message: pendingReviews == 0
                    ? 'Contrôles'
                    : '$pendingReviews contrôle(s) à vérifier',
                child: OutlinedButton.icon(
                  onPressed: onOpenReviews,
                  icon: const Icon(Icons.fact_check_outlined),
                  label: const Text('Contrôles'),
                ),
              ),
            ),
            if (user.canWritePage(AppPage.machines))
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: FilledButton.icon(
                  onPressed: onAdd,
                  icon: const Icon(Icons.add),
                  label: const Text('Ajouter'),
                ),
              ),
          ],
        ),
        const SizedBox(height: 14),
        if (hasActive)
          Glass(
            padding: const EdgeInsets.all(14),
            child: const Row(
              children: [
                Icon(Icons.engineering_rounded, color: Color(0xFF7E22CE)),
                SizedBox(width: 9),
                Expanded(
                  child: Text(
                    'Une opération est en cours. Terminez-la avant d’en démarrer une autre.',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 14),
        if (machines.isEmpty)
          const Empty(
            icon: Icons.precision_manufacturing_outlined,
            title: 'Aucune machine',
            detail: 'Ajoutez une machine et son opérateur responsable.',
          )
        else
          Wrap(
            spacing: 14,
            runSpacing: 14,
            children: machines.expand((m) => m.units.map((unit) {
              final allowed = user.isOperator && m.operatorIds.contains(user.id);
              return SizedBox(
                width: 330,
                child: Glass(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (!m.temporary && (unit.image ?? m.image) != null)
                        ClipRRect(
                          borderRadius: BorderRadius.circular(17),
                          child: Image.memory(unit.image ?? m.image!, height: 130, width: double.infinity, fit: BoxFit.cover),
                        )
                      else
                        Container(height: 130, width: double.infinity, alignment: Alignment.center, decoration: BoxDecoration(color: const Color(0xFFFFF7ED), borderRadius: BorderRadius.circular(17)), child: const Icon(Icons.local_shipping_outlined, size: 48, color: Color(0xFFB45309))),
                      const SizedBox(height: 10),
                      Text(
                        m.temporary ? '${m.name} · travail externe' : '${m.name} · exemplaire n°${unit.number}',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      Text(
                        m.temporary
                            ? 'Fin prévue : ${m.deadline == null ? 'non définie' : dateText(m.deadline!)} · ${m.type == MachineType.roulage ? 'Roulage' : 'Standard'}'
                            : 'Exemplaire ${unit.usable ? 'disponible' : 'indisponible'} · ${m.type == MachineType.roulage ? 'Roulage' : 'Standard'}',
                        style: const TextStyle(color: Color(0xFF725280)),
                      ),
                      Text(
                        'Catégorie : ${categoryName(m.categoryId)}',
                        style: const TextStyle(color: Color(0xFF725280)),
                      ),
                      Text(
                        'Produit fabriqué : ${productName(m.outputId)}',
                        style: const TextStyle(
                          color: Color(0xFF15803D),
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (m.temporary) ...[
                        Text('Matière envoyée : ${productName(m.temporaryInputProductId ?? '')} · ${m.temporaryInputPieces ?? 0} pièce(s)', maxLines: 2),
                        Text('Quantité attendue : ${m.plannedPieces ?? 0}${m.hopperPieces == null ? ' pièces' : ' cadous · ${m.hopperPieces} tôle(s)/cadous'}', maxLines: 2),
                      ]
                      else Text('Responsable : ${m.operatorIds.map(userName).join(', ')}', maxLines: 1, overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 12),
                      if (m.temporary)
                        const Text('À la validation : matière déduite et production ajoutée au stock.', style: TextStyle(color: Color(0xFFB45309), fontWeight: FontWeight.w700))
                      else if (allowed && unit.usable)
                        FilledButton.icon(
                          onPressed: hasActive ? null : () => onStart(m, unit),
                          icon: const Icon(Icons.play_arrow_rounded),
                          label: const Text('Démarrer'),
                        )
                      else if (allowed)
                        const Text(
                          'Cet exemplaire est indisponible',
                          style: TextStyle(color: Color(0xFFB45309), fontWeight: FontWeight.w700),
                        )
                      else
                        const Text(
                          'Accès réservé à l’opérateur assigné',
                          style: TextStyle(
                            color: Color(0xFF725280),
                            fontSize: 12,
                          ),
                        ),
                      if (user.canWritePage(AppPage.machines) && !m.temporary)
                        TextButton.icon(
                          onPressed: () => onManage(m),
                          icon: const Icon(Icons.build_circle_outlined),
                          label: const Text('Gérer les exemplaires'),
                        ),
                    ],
                  ),
                ),
              );
            })).toList(),
          ),
        const SizedBox(height: 24),
        if (operations.isNotEmpty)
          const Text(
            'Suivi des opérations',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
          ),
        const SizedBox(height: 8),
        if (operations.isNotEmpty)
          Glass(
            child: Column(
              children: operations.reversed.map((op) {
                final mine = op.operatorId == user.id;
                return ListTile(
                  leading: Icon(
                    op.active
                        ? Icons.play_circle_fill_rounded
                        : op.completionDraft
                        ? Icons.edit_note_rounded
                        : op.needsReview
                        ? Icons.warning_amber_rounded
                        : Icons.verified_rounded,
                    color: op.active
                        ? const Color(0xFF9333EA)
                        : op.completionDraft
                        ? const Color(0xFFF59E0B)
                        : op.needsReview
                        ? const Color(0xFFB45309)
                        : const Color(0xFF15803D),
                  ),
                  title: Text(
                    op.externalProduction
                        ? 'Travail externe temporaire'
                        : op.active
                        ? 'Opération en cours'
                        : op.completionDraft
                        ? 'Brouillon à valider'
                        : op.needsReview
                        ? 'Contrôle requis'
                        : 'Opération terminée',
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  subtitle: Text(
                    op.externalProduction
                        ? 'À ajouter au stock après validation'
                        : '${userName(op.operatorId)} · début ${dateText(op.startedAt)}',
                  ),
                  trailing: op.active && mine
                      ? FilledButton(
                          onPressed: () => onFinish(op),
                          child: const Text('Terminer'),
                        )
                      : Text(
                          op.active
                              ? 'En cours'
                              : op.completionDraft
                              ? 'En attente de validation'
                              : op.hopperPieces == null
                              ? '${op.outputPieces} pièces'
                              : '${op.outputPieces} cadous',
                        ),
                );
              }).toList(),
            ),
          ),
      ],
    ),
  );
}

class CategoriesPage extends StatelessWidget {
  const CategoriesPage({
    super.key,
    required this.categories,
    required this.products,
    required this.admin,
    required this.onAdd,
    required this.onEdit,
  });
  final List<ProductCategory> categories;
  final List<Product> products;
  final bool admin;
  final VoidCallback onAdd;
  final ValueChanged<ProductCategory> onEdit;

  @override
  Widget build(BuildContext context) => Page(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHero(
          icon: Icons.category_rounded,
          title: 'Catégories',
          subtitle: 'Organisez les produits utilisés par vos machines.',
          trailing: admin
              ? IconButton.filled(
                  onPressed: onAdd,
                  icon: const Icon(Icons.add),
                  tooltip: 'Ajouter une catégorie',
                )
              : null,
        ),
        const SizedBox(height: 16),
        if (categories.isEmpty)
          const Empty(icon: Icons.category_outlined, title: 'Aucune catégorie', detail: 'Créez une catégorie puis sélectionnez ses produits.')
        else
          ...categories.map((category) {
            final names = products
                .where(
                  (product) =>
                      product.canBeUsedInMachine &&
                      category.productIds.contains(product.id),
                )
                .map((product) => product.name)
                .join(' · ');
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Glass(
                child: ListTile(
                  leading: CategoryImage(category: category, size: 48),
                  title: Text(category.name, style: const TextStyle(fontWeight: FontWeight.w900)),
                  subtitle: Text(names.isEmpty ? 'Aucun produit sélectionné' : names, maxLines: 2, overflow: TextOverflow.ellipsis),
                  trailing: admin
                      ? IconButton.filledTonal(
                          icon: const Icon(Icons.edit_outlined),
                          onPressed: () => onEdit(category),
                          tooltip: 'Modifier',
                        )
                      : null,
                ),
              ),
            );
          }),
      ],
    ),
  );
}

class CategoryForm extends StatefulWidget {
  const CategoryForm({super.key, this.initial});
  final ProductCategory? initial;
  @override
  State<CategoryForm> createState() => _CategoryFormState();
}

class _CategoryFormState extends State<CategoryForm> {
  final name = TextEditingController();
  Uint8List? image;
  @override
  void initState() {
    super.initState();
    name.text = widget.initial?.name ?? '';
    if (widget.initial != null && widget.initial!.image.isNotEmpty) {
      image = widget.initial!.image;
    }
  }
  Future<void> pickImage() async {
    final file = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 82,
      maxWidth: 1600,
    );
    if (file == null) return;
    final bytes = await file.readAsBytes();
    if (mounted) setState(() => image = bytes);
  }
  void save() {
    if (name.text.trim().isEmpty || image == null) {
      message(context, 'Ajoutez une photo et un nom.');
      return;
    }
    Navigator.pop(context, ProductCategory(
      id: widget.initial?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
      name: name.text.trim(),
      productIds: widget.initial?.productIds ?? const [],
      image: image!,
    ));
  }
  @override
  Widget build(BuildContext context) => FormShell(
    title: widget.initial == null ? 'Ajouter une catégorie' : 'Modifier la catégorie',
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      TextField(controller: name, decoration: const InputDecoration(labelText: 'Nom de la catégorie *')),
      const SizedBox(height: 14),
      ImageInput(bytes: image, label: 'Photo de la catégorie *', onTap: pickImage),
      const SizedBox(height: 12),
      const Text('Les produits bruts seront rattachés à cette catégorie lors de leur ajout.', style: TextStyle(color: Color(0xFF725280), fontSize: 12)),
      const SizedBox(height: 20),
      SizedBox(width: double.infinity, child: FilledButton(onPressed: save, child: const Text('Enregistrer la catégorie'))),
    ]),
  );
}

class MachineUnitsPage extends StatefulWidget {
  const MachineUnitsPage({super.key, required this.machine});
  final FactoryMachine machine;
  @override
  State<MachineUnitsPage> createState() => _MachineUnitsPageState();
}

class _MachineUnitsPageState extends State<MachineUnitsPage> {
  late List<MachineUnit> units;
  @override
  void initState() { super.initState(); units = [...widget.machine.units]; }
  Future<void> changeState(MachineUnit unit) async {
    final choice = await showModalBottomSheet<MachineUnitState>(
      context: context,
      builder: (context) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(leading: const Icon(Icons.check_circle_outline, color: Color(0xFF15803D)), title: const Text('Disponible'), onTap: () => Navigator.pop(context, MachineUnitState.ready)),
        ListTile(leading: const Icon(Icons.schedule_outlined, color: Color(0xFFB45309)), title: const Text('Panne temporaire (24 h)'), onTap: () => Navigator.pop(context, MachineUnitState.temporarilyUnavailable)),
        ListTile(leading: const Icon(Icons.block_outlined, color: Color(0xFFB42318)), title: const Text('Retiré définitivement'), onTap: () => Navigator.pop(context, MachineUnitState.retired)),
      ])),
    );
    if (choice == null || !mounted) return;
    var unavailableUntil = choice == MachineUnitState.temporarilyUnavailable
        ? DateTime.now().add(const Duration(hours: 24))
        : null;
    if (choice == MachineUnitState.temporarilyUnavailable) {
      final hours = TextEditingController(text: '24');
      final duration = await showDialog<int>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Durée de la panne'),
          content: TextField(
            controller: hours,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(labelText: 'Nombre d’heures'),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
            FilledButton(onPressed: () => Navigator.pop(context, int.tryParse(hours.text)), child: const Text('Confirmer')),
          ],
        ),
      );
      if (!mounted || duration == null || duration <= 0) return;
      unavailableUntil = DateTime.now().add(Duration(hours: duration));
    }
    setState(() {
      final index = units.indexOf(unit);
      units[index] = MachineUnit(
        number: unit.number,
        image: unit.image,
        state: choice,
        unavailableUntil: unavailableUntil,
      );
    });
  }
  @override
  Widget build(BuildContext context) => Scaffold(
    body: Aura(child: SafeArea(child: Column(children: [
      Padding(padding: const EdgeInsets.all(14), child: Row(children: [IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.arrow_back)), Expanded(child: Text('Exemplaires · ${widget.machine.name}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900)))])),
      Expanded(child: ListView(padding: const EdgeInsets.all(20), children: units.map((unit) {
        final usable = unit.usable;
        final text = usable ? 'Disponible' : unit.state == MachineUnitState.retired ? 'Retiré définitivement' : 'En panne jusqu’au ${dateText(unit.unavailableUntil!)}';
        return Padding(padding: const EdgeInsets.only(bottom: 10), child: Glass(child: ListTile(
          leading: Icon(usable ? Icons.check_circle_rounded : Icons.warning_amber_rounded, color: usable ? const Color(0xFF15803D) : const Color(0xFFB45309)),
          title: Text('Exemplaire n°${unit.number}', style: const TextStyle(fontWeight: FontWeight.w900)),
          subtitle: Text(text), trailing: const Icon(Icons.edit_outlined), onTap: () => changeState(unit),
        )));
      }).toList())),
      Padding(padding: const EdgeInsets.all(20), child: SizedBox(width: double.infinity, child: FilledButton(onPressed: () => Navigator.pop(context, FactoryMachine(id: widget.machine.id, name: widget.machine.name, type: widget.machine.type, categoryId: widget.machine.categoryId, outputId: widget.machine.outputId, units: units, operatorIds: widget.machine.operatorIds, image: widget.machine.image, temporary: widget.machine.temporary, deadline: widget.machine.deadline, plannedPieces: widget.machine.plannedPieces, hopperPieces: widget.machine.hopperPieces, temporaryInputProductId: widget.machine.temporaryInputProductId, temporarySourceDepotId: widget.machine.temporarySourceDepotId, temporaryInputPieces: widget.machine.temporaryInputPieces)), child: const Text('Enregistrer les états')))),
    ]))),
  );
}

class ReviewsPage extends StatefulWidget {
  const ReviewsPage({super.key, required this.operations, required this.product, required this.userName, required this.depots, required this.admin, required this.onApprove});
  final List<Operation> operations;
  final Product? Function(String) product;
  final String Function(String) userName;
  final List<Depot> depots;
  final bool admin;
  final Future<void> Function(Operation operation, String depotId) onApprove;

  @override
  State<ReviewsPage> createState() => _ReviewsPageState();
}

class _ReviewsPageState extends State<ReviewsPage> {
  final selectedDepots = <String, String>{};

  @override
  Widget build(BuildContext context) {
    final pendingOperations = widget.operations
        .where((operation) => operation.needsReview)
        .toList();
    return Page(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHero(
          icon: pendingOperations.isEmpty
              ? Icons.verified_rounded
              : Icons.fact_check_rounded,
          title: 'Contrôles',
          subtitle: pendingOperations.isEmpty
              ? 'Tout est vérifié. Aucune action n’est nécessaire.'
              : '${pendingOperations.length} opération(s) demandent votre attention.',
        ),
        const SizedBox(height: 18),
        if (pendingOperations.isEmpty)
          Glass(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 30),
            child: const Center(
              child: Column(
                children: [
                  Icon(Icons.task_alt_rounded, color: Color(0xFF16A34A), size: 48),
                  SizedBox(height: 12),
                  Text('Aucun contrôle en attente', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
                  SizedBox(height: 6),
                  Text('Les opérations à contrôler apparaîtront ici.', textAlign: TextAlign.center, style: TextStyle(color: AppPalette.muted)),
                ],
              ),
            ),
          )
        else
          ...pendingOperations.reversed.map(
            (operation) => Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Glass(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.warning_amber_rounded, color: Color(0xFFB45309)),
                        SizedBox(width: 8),
                        Text('Pièces restantes à contrôler', style: TextStyle(fontWeight: FontWeight.w900)),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text('${widget.product(operation.productId)?.name ?? 'Produit'} · ${operation.pieces - (operation.outputPieces ?? 0)} pièce(s) · ${widget.userName(operation.operatorId)}'),
                    if (operation.remainderImage != null) ...[
                      const SizedBox(height: 12),
                      ClipRRect(borderRadius: BorderRadius.circular(14), child: Image.memory(operation.remainderImage!, height: 150, width: double.infinity, fit: BoxFit.cover)),
                    ],
                    if (widget.admin) ...[
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        initialValue: selectedDepots[operation.id],
                        decoration: const InputDecoration(labelText: 'Dépôt qui reçoit les pièces restantes *'),
                        items: widget.depots.map((depot) => DropdownMenuItem(value: depot.id, child: Text(depot.name))).toList(),
                        onChanged: (value) => setState(() => selectedDepots[operation.id] = value!),
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: selectedDepots[operation.id] == null
                              ? null
                              : () async {
                                  await widget.onApprove(
                                    operation,
                                    selectedDepots[operation.id]!,
                                  );
                                  if (mounted) setState(() {});
                                },
                          icon: const Icon(Icons.task_alt_rounded),
                          label: const Text('Accepter et terminer l’opération'),
                        ),
                      ),
                    ] else
                      const Padding(
                        padding: EdgeInsets.only(top: 12),
                        child: Text('En attente de l’approbation du responsable.', style: TextStyle(color: AppPalette.muted)),
                      ),
                  ],
                ),
              ),
            ),
          ),
      ],
    ),
  );
  }
}

class ValidationPage extends StatelessWidget {
  const ValidationPage({
    super.key,
    required this.products,
    required this.depots,
    required this.stockDrafts,
    required this.saleDrafts,
    required this.returnDrafts,
    required this.operationDrafts,
    required this.transferDrafts,
    required this.onApproveStock,
    required this.onEditStock,
    required this.onCancelStock,
    required this.onApproveSale,
    required this.onEditSale,
    required this.onCancelSale,
    required this.onApproveReturn,
    required this.onEditReturn,
    required this.onRejectReturn,
    required this.onCancelReturn,
    required this.onApproveOperation,
    required this.onEditOperation,
    required this.onCancelOperation,
    required this.onApproveTransfer,
    required this.onCancelTransfer,
  });
  final List<Product> products;
  final List<Depot> depots;
  final List<StockAddition> stockDrafts;
  final List<Sale> saleDrafts;
  final List<SaleReturn> returnDrafts;
  final List<Operation> operationDrafts;
  final List<StockTransfer> transferDrafts;
  final Future<void> Function(StockAddition) onApproveStock;
  final Future<void> Function(StockAddition) onEditStock;
  final Future<void> Function(StockAddition) onCancelStock;
  final Future<void> Function(Sale) onApproveSale;
  final Future<void> Function(Sale) onEditSale;
  final Future<void> Function(Sale) onCancelSale;
  final Future<void> Function(SaleReturn) onApproveReturn;
  final Future<void> Function(SaleReturn) onEditReturn;
  final Future<void> Function(SaleReturn) onRejectReturn;
  final Future<void> Function(SaleReturn) onCancelReturn;
  final Future<void> Function(Operation) onApproveOperation;
  final Future<void> Function(Operation) onEditOperation;
  final Future<void> Function(Operation) onCancelOperation;
  final Future<void> Function(StockTransfer) onApproveTransfer;
  final Future<void> Function(StockTransfer) onCancelTransfer;

  Product? _product(String id) {
    for (final product in products) {
      if (product.id == id) return product;
    }
    return null;
  }

  String _depotName(String id) => depots
      .where((depot) => depot.id == id)
      .map((depot) => depot.name)
      .firstOrNull ??
      'Dépôt inconnu';

  Future<void> _editStock(BuildContext context, StockAddition item) async {
    final quantity = TextEditingController(text: formatNumber(item.quantity));
    final receipt = TextEditingController(text: item.receiptNumber);
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Corriger l’achat'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: quantity,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(labelText: 'Quantité (${item.unit.shortLabel})'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: receipt,
              decoration: const InputDecoration(labelText: 'N° de bon'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Enregistrer')),
        ],
      ),
    );
    final product = _product(item.productId);
    final entered = number(quantity.text);
    if (saved != true || product == null || entered <= 0 || receipt.text.trim().isEmpty) return;
    await onEditStock(StockAddition(
      id: item.id,
      productId: item.productId,
      depotId: item.depotId,
      pieces: piecesForQuantity(product, entered, item.unit),
      receiptNumber: receipt.text.trim(),
      supplierId: item.supplierId,
      quantity: entered,
      unit: item.unit,
      images: item.images,
      addedAt: item.addedAt,
    ));
  }

  Future<void> _editSale(BuildContext context, Sale item) async {
    final quantity = TextEditingController(text: formatNumber(item.quantity));
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Corriger la vente'),
        content: TextField(
          controller: quantity,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: 'Quantité (${item.unit.shortLabel})'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Enregistrer')),
        ],
      ),
    );
    final product = _product(item.productId);
    final entered = number(quantity.text);
    if (saved != true || product == null || entered <= 0) return;
    await onEditSale(Sale(
      id: item.id,
      productId: item.productId,
      depotId: item.depotId,
      clientId: item.clientId,
      pieces: piecesForQuantity(product, entered, item.unit),
      quantity: entered,
      unit: item.unit,
      images: item.images,
      createdAt: item.createdAt,
    ));
  }

  Future<void> _editReturn(BuildContext context, SaleReturn item) async {
    final pieces = TextEditingController(text: '${item.pieces}');
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Corriger le retour'),
        content: TextField(
          controller: pieces,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(labelText: 'Pièces retournées'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Enregistrer')),
        ],
      ),
    );
    final value = int.tryParse(pieces.text);
    if (saved != true || value == null || value <= 0) return;
    await onEditReturn(SaleReturn(
      id: item.id,
      saleId: item.saleId,
      productId: item.productId,
      depotId: item.depotId,
      pieces: value,
      createdAt: item.createdAt,
      status: ReturnValidationStatus.pending,
    ));
  }

  Future<void> _editOperation(BuildContext context, Operation operation) async {
    final output = TextEditingController(text: '${operation.outputPieces ?? 0}');
    final remainder = TextEditingController(text: '${operation.remainderPieces}');
    final scrap = TextEditingController(text: '${operation.scrapPieces}');
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Corriger la production'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: output, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Pièces fabriquées')),
            const SizedBox(height: 10),
            TextField(controller: remainder, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Pièces restantes (retour au stock)')),
            const SizedBox(height: 10),
            TextField(controller: scrap, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Pièces perdues / déchets')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Enregistrer')),
        ],
      ),
    );
    final outputPieces = int.tryParse(output.text);
    final remainderPieces = int.tryParse(remainder.text);
    final scrapPieces = int.tryParse(scrap.text);
    if (saved != true ||
        outputPieces == null ||
        remainderPieces == null ||
        scrapPieces == null ||
        outputPieces < 0 ||
        remainderPieces < 0 ||
        scrapPieces < 0 ||
        (remainderPieces > 0 && operation.remainderDepotId == null) ||
        (scrapPieces > 0 && operation.scrapDepotId == null) ||
        (!operation.externalProduction &&
            (operation.hopperPieces == null
                ? outputPieces + remainderPieces + scrapPieces
                : outputPieces * operation.hopperPieces! + remainderPieces + scrapPieces) != operation.pieces)) {
      return;
    }
    operation.outputPieces = outputPieces;
    operation.remainderPieces = remainderPieces;
    operation.scrapPieces = scrapPieces;
    await onEditOperation(operation);
  }

  Widget _draftCard({
    required IconData icon,
    required String title,
    required String detail,
    VoidCallback? onEdit,
    required Future<void> Function() onApprove,
    Future<void> Function()? onReject,
    Future<void> Function()? onCancel,
  }) => Glass(
    padding: const EdgeInsets.all(14),
    child: Row(
      children: [
        Icon(icon, color: const Color(0xFFF59E0B)),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: const TextStyle(fontWeight: FontWeight.w900)), Text(detail, style: const TextStyle(color: AppPalette.muted))])),
        if (onReject != null)
          TextButton(
            onPressed: () async => onReject(),
            child: const Text('Refuser'),
          ),
        if (onCancel != null)
          TextButton(
            onPressed: () async => onCancel(),
            style: TextButton.styleFrom(foregroundColor: const Color(0xFFB91C1C)),
            child: const Text('Annuler'),
          ),
        if (onEdit != null)
          TextButton(onPressed: onEdit, child: const Text('Modifier')),
        FilledButton(onPressed: () async => onApprove(), child: const Text('Valider')),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final total = stockDrafts.length + saleDrafts.length + returnDrafts.length + operationDrafts.length + transferDrafts.length;
    return Page(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SectionHero(
          icon: Icons.verified_user_rounded,
          title: 'Validations',
          subtitle: total == 0
              ? 'Toutes les opérations sont à jour.'
              : '$total brouillon(s) attendent votre contrôle.',
        ),
        const SizedBox(height: 16),
        Text('Brouillons à valider ($total)', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
        const SizedBox(height: 8),
        const Text('Chaque brouillon peut être corrigé, validé ou annulé. Une annulation ne modifie pas le stock.', style: TextStyle(color: AppPalette.muted)),
        const SizedBox(height: 16),
        if (total == 0) const Empty(icon: Icons.task_alt_rounded, title: 'Aucun brouillon', detail: 'Toutes les opérations sont validées.') else ...[
          ...stockDrafts.map((item) => Padding(padding: const EdgeInsets.only(bottom: 10), child: _draftCard(icon: Icons.shopping_cart_checkout_rounded, title: 'Achat · ${_product(item.productId)?.name ?? 'Produit'}', detail: '${formatQuantity(item.quantity, item.unit)} · Bon ${item.receiptNumber}', onEdit: () => _editStock(context, item), onCancel: () => onCancelStock(item), onApprove: () => onApproveStock(item)))),
          ...saleDrafts.map((item) => Padding(padding: const EdgeInsets.only(bottom: 10), child: _draftCard(icon: Icons.point_of_sale_rounded, title: 'Vente · ${_product(item.productId)?.name ?? 'Produit'}', detail: formatQuantity(item.quantity, item.unit), onEdit: () => _editSale(context, item), onCancel: () => onCancelSale(item), onApprove: () => onApproveSale(item)))),
          ...returnDrafts.map((item) {
            final product = _product(item.productId);
            final quantity = product == null
                ? '${item.pieces} pièce(s)'
                : productQuantityLabel(product, item.pieces);
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _draftCard(
                icon: Icons.assignment_return_rounded,
                title: 'Retour client · ${product?.name ?? 'Produit'}',
                detail: '$quantity · en attente',
                onEdit: () => _editReturn(context, item),
                onApprove: () => onApproveReturn(item),
                onReject: () => onRejectReturn(item),
                onCancel: () => onCancelReturn(item),
              ),
            );
          }),
          ...operationDrafts.map((item) => Padding(padding: const EdgeInsets.only(bottom: 10), child: _draftCard(icon: item.externalProduction ? Icons.local_shipping_outlined : Icons.precision_manufacturing_rounded, title: item.externalProduction ? 'Travail externe · ${_product(item.outputProductId ?? item.productId)?.name ?? 'Produit'}' : 'Production · ${_product(item.productId)?.name ?? 'Produit'}', detail: item.externalProduction ? '${item.outputPieces ?? 0} à ajouter au stock · sans opérateur' : '${item.outputPieces ?? 0} fabriquées · ${item.remainderPieces} restantes · ${item.scrapPieces} déchet(s)', onEdit: () => _editOperation(context, item), onCancel: () => onCancelOperation(item), onApprove: () => onApproveOperation(item)))),
          ...transferDrafts.map((item) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _draftCard(
              icon: Icons.swap_horiz_rounded,
              title: 'Transfert · ${_product(item.productId)?.name ?? 'Produit'}',
              detail: '${item.pieces} pièce(s) · ${_depotName(item.sourceDepotId)} → ${_depotName(item.destinationDepotId)}',
              onCancel: () => onCancelTransfer(item),
              onApprove: () => onApproveTransfer(item),
            ),
          )),
        ],
      ]),
    );
  }
}

class PayrollPage extends StatefulWidget {
  const PayrollPage({
    super.key,
    required this.users,
    required this.products,
    required this.operations,
    required this.payments,
    required this.meterRate,
    required this.onPay,
    required this.onRateChanged,
  });

  final List<AppUser> users;
  final List<Product> products;
  final List<Operation> operations;
  final List<OperatorPayment> payments;
  final double meterRate;
  final Future<void> Function(String operatorId, double amount) onPay;
  final Future<void> Function(double rate) onRateChanged;

  @override
  State<PayrollPage> createState() => _PayrollPageState();
}

class _PayrollPageState extends State<PayrollPage> {
  late double meterRate = widget.meterRate;

  Product? _product(String id) {
    for (final product in widget.products) {
      if (product.id == id) return product;
    }
    return null;
  }

  double _meters(Operation operation) =>
      operation.pieces * (_product(operation.productId)?.lengthMeters ?? 0);

  bool _inMonth(DateTime value, DateTime month) =>
      value.year == month.year && value.month == month.month;

  Future<void> _pay(BuildContext context, AppUser operator) async {
    final amount = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Paiement · ${operator.fullName}'),
        content: TextField(
          controller: amount,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'Montant payé (DH)'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Enregistrer'),
          ),
        ],
      ),
    );
    final value = number(amount.text);
    if (confirmed != true || value <= 0) return;
    await widget.onPay(operator.id, value);
  }

  Future<void> _changeRate() async {
    final value = TextEditingController(text: formatNumber(meterRate));
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Modifier le prix du mètre'),
        content: TextField(
          controller: value,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'Prix par mètre (DH)'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Enregistrer')),
        ],
      ),
    );
    final rate = number(value.text);
    if (confirmed != true || rate <= 0) return;
    await widget.onRateChanged(rate);
    if (mounted) setState(() => meterRate = rate);
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final operators = widget.users.where((user) => user.isOperator).toList();
    return Page(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHero(
            icon: Icons.payments_rounded,
            title: 'Paie des opérateurs',
            subtitle: 'Seules les opérations validées comptent · ${formatNumber(meterRate)} DH par mètre.',
            trailing: OutlinedButton.icon(
              onPressed: _changeRate,
              icon: const Icon(Icons.edit_outlined),
              label: const Text('Prix'),
            ),
          ),
          const SizedBox(height: 14),
          const Text(
            'Le paiement est facultatif : un montant supérieur crée une avance, un montant inférieur laisse un reste à payer.',
            style: TextStyle(color: AppPalette.muted),
          ),
          const SizedBox(height: 16),
          if (operators.isEmpty)
            const Empty(
              icon: Icons.engineering_outlined,
              title: 'Aucun opérateur',
              detail: 'Ajoutez un utilisateur avec le rôle Opérateur.',
            )
          else
            ...operators.map((operator) {
              final approved = widget.operations
                  .where((operation) =>
                      operation.operatorId == operator.id &&
                      operation.validatedAt != null &&
                      !operation.completionDraft)
                  .toList();
              final meters = approved.fold<double>(
                0,
                (total, operation) => total + _meters(operation),
              );
              final monthMeters = approved
                  .where((operation) => _inMonth(operation.validatedAt!, now))
                  .fold<double>(0, (total, operation) => total + _meters(operation));
              final earned = meters * meterRate;
              final paid = widget.payments
                  .where((payment) => payment.operatorId == operator.id)
                  .fold<double>(0, (total, payment) => total + payment.amount);
              final balance = earned - paid;
              final showWarning = now.day >= 25 && balance > 0;
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Glass(
                  padding: const EdgeInsets.all(15),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          CircleAvatar(
                            backgroundColor: AppPalette.soft,
                            foregroundColor: AppPalette.primary,
                            child: Text(operator.fullName.substring(0, 1).toUpperCase()),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(operator.fullName, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
                          ),
                          FilledButton.icon(
                            onPressed: () => _pay(context, operator),
                            icon: const Icon(Icons.add_card_rounded),
                            label: const Text('Payer'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Text('Ce mois : ${formatNumber(monthMeters)} m · ${formatNumber(monthMeters * meterRate)} DH', style: const TextStyle(fontWeight: FontWeight.w800)),
                      const SizedBox(height: 5),
                      Text('Total validé : ${formatNumber(meters)} m · ${formatNumber(earned)} DH'),
                      Text('Total payé : ${formatNumber(paid)} DH'),
                      const SizedBox(height: 8),
                      if (balance > 0)
                        Text('Reste à payer : ${formatNumber(balance)} DH', style: const TextStyle(color: Color(0xFFB45309), fontWeight: FontWeight.w900))
                      else if (balance < 0)
                        Text('Avance : ${formatNumber(-balance)} DH · équivaut à ${formatNumber((-balance) / meterRate)} m', style: const TextStyle(color: Color(0xFF15803D), fontWeight: FontWeight.w900))
                      else
                        const Text('Solde réglé', style: TextStyle(color: Color(0xFF15803D), fontWeight: FontWeight.w900)),
                      if (showWarning) ...[
                        const SizedBox(height: 9),
                        const Row(children: [Icon(Icons.warning_amber_rounded, color: Color(0xFFF59E0B)), SizedBox(width: 7), Expanded(child: Text('Fin de mois : reste de paie à suivre.', style: TextStyle(color: Color(0xFF92400E), fontWeight: FontWeight.w800)))]),
                      ],
                    ],
                  ),
                ),
              );
            }),
        ],
      ),
    );
  }
}

class DeveloperModePage extends StatefulWidget {
  const DeveloperModePage({
    super.key,
    required this.products,
    required this.categories,
    required this.depots,
    required this.purchases,
    required this.sales,
    required this.machines,
    required this.operations,
    required this.transfers,
    required this.returns,
    required this.database,
    required this.onChanged,
  });
  final List<Product> products;
  final List<ProductCategory> categories;
  final List<Depot> depots;
  final List<StockAddition> purchases;
  final List<Sale> sales;
  final List<FactoryMachine> machines;
  final List<Operation> operations;
  final List<StockTransfer> transfers;
  final List<SaleReturn> returns;
  final AppDatabase database;
  final Future<void> Function() onChanged;
  @override
  State<DeveloperModePage> createState() => _DeveloperModePageState();
}

class _DeveloperModePageState extends State<DeveloperModePage> {
  Future<T?> _select<T>({
    required String title,
    required List<T> values,
    required String Function(T) label,
  }) async {
    T? selected;
    return showDialog<T>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(title),
          content: DropdownButtonFormField<T>(
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Élément'),
            items: values.map((value) => DropdownMenuItem(value: value, child: Text(label(value), overflow: TextOverflow.ellipsis))).toList(),
            onChanged: (value) => setDialogState(() => selected = value),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
            FilledButton(
              onPressed: selected == null ? null : () => Navigator.pop(context, selected),
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFFB91C1C)),
              child: const Text('Continuer'),
            ),
          ],
        ),
      ),
    );
  }

  Future<bool> _confirm(String text) async => await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Confirmer l’action irréversible'),
      content: Text(text),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFFB91C1C)),
          child: const Text('Supprimer'),
        ),
      ],
    ),
  ) ?? false;

  Future<void> _finish(String text) async {
    await widget.onChanged();
    if (!mounted) return;
    message(context, text);
    Navigator.pop(context);
  }

  Future<void> _deleteProduct() async {
    final product = await _select(title: 'Supprimer un produit', values: widget.products, label: (item) => item.name);
    if (product == null || !await _confirm('Le produit et tous ses achats, ventes, transferts et opérations associés seront supprimés.')) return;
    try {
      await widget.database.deleteProductAndHistory(product.id);
      await _finish('Produit supprimé.');
    } on StateError catch (error) {
      if (mounted) message(context, error.message);
    }
  }

  Future<void> _deleteCategory() async {
    final category = await _select(title: 'Supprimer une catégorie', values: widget.categories, label: (item) => item.name);
    if (category == null || !await _confirm('La catégorie sera supprimée définitivement.')) return;
    await widget.database.deleteCategory(category.id);
    await _finish('Catégorie supprimée.');
  }

  Future<void> _deletePurchase() async {
    final purchase = await _select(
      title: 'Supprimer un achat', values: widget.purchases,
      label: (item) => 'Achat #${item.id ?? '—'} · ${item.pieces} pièce(s)',
    );
    if (purchase?.id == null || !await _confirm('Cet achat sera supprimé définitivement.')) return;
    await widget.database.deleteStockAddition(purchase!.id!);
    await _finish('Achat supprimé.');
  }

  Future<void> _editPurchase() async {
    final item = await _select(title: 'Modifier un achat', values: widget.purchases, label: (item) => 'Achat #${item.id ?? '—'} · ${item.pieces} pièce(s)');
    if (item == null) return;
    final pieces = await _editPieces('Modifier l’achat', item.pieces);
    if (pieces == null || pieces <= 0) return;
    await widget.database.updateStockAddition(StockAddition(id: item.id, productId: item.productId, depotId: item.depotId, pieces: pieces, receiptNumber: item.receiptNumber, supplierId: item.supplierId, quantity: pieces.toDouble(), unit: InventoryUnit.piece, images: item.images, addedAt: item.addedAt, draft: item.draft));
    await _finish('Achat modifié.');
  }

  Future<void> _deleteSale() async {
    final sale = await _select(
      title: 'Supprimer une vente', values: widget.sales,
      label: (item) => 'Vente · ${item.pieces} pièce(s) · ${dateText(item.createdAt)}',
    );
    if (sale == null || !await _confirm('La vente et ses éventuels retours seront supprimés définitivement.')) return;
    await widget.database.deleteSaleAndReturns(sale.id);
    await _finish('Vente supprimée.');
  }

  Future<void> _editSale() async {
    final item = await _select(title: 'Modifier une vente', values: widget.sales, label: (item) => 'Vente · ${item.pieces} pièce(s) · ${dateText(item.createdAt)}');
    if (item == null) return;
    final pieces = await _editPieces('Modifier la vente', item.pieces);
    if (pieces == null || pieces <= 0) return;
    await widget.database.updateSale(Sale(id: item.id, productId: item.productId, depotId: item.depotId, clientId: item.clientId, pieces: pieces, quantity: pieces.toDouble(), unit: InventoryUnit.piece, images: item.images, createdAt: item.createdAt, draft: item.draft));
    await _finish('Vente modifiée.');
  }

  Future<String?> _editText(String title, String initial, String label) async {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(controller: controller, autofocus: true, decoration: InputDecoration(labelText: label)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('Enregistrer')),
        ],
      ),
    );
  }

  Future<int?> _editPieces(String title, int initial) async {
    final value = await _editText(title, '$initial', 'Quantité en pièces');
    final pieces = int.tryParse(value ?? '');
    return pieces != null && pieces >= 0 ? pieces : null;
  }

  Future<void> _editCategory() async {
    final item = await _select(title: 'Modifier une catégorie', values: widget.categories, label: (item) => item.name);
    if (item == null) return;
    final name = await _editText('Modifier la catégorie', item.name, 'Nom de la catégorie');
    if (name == null || name.isEmpty) return;
    await widget.database.updateCategory(ProductCategory(id: item.id, name: name, productIds: item.productIds, image: item.image));
    await _finish('Catégorie modifiée.');
  }

  Future<void> _editProduct() async {
    final item = await _select(title: 'Modifier un produit', values: widget.products, label: (item) => item.name);
    if (item == null) return;
    final name = await _editText('Modifier le produit', item.name, 'Nom du produit');
    if (name == null || name.isEmpty) return;
    await widget.database.updateProduct(Product(id: item.id, name: name, reference: item.reference, width: item.width, lengthMeters: item.lengthMeters, lengthUnit: item.lengthUnit, thickness: item.thickness, kind: item.kind, initialStock: item.initialStock, initialDepotId: item.initialDepotId, material: item.material, hoseUnit: item.hoseUnit, metersPerPiece: item.metersPerPiece, diameter: item.diameter, image: item.image, parentProductId: item.parentProductId));
    await _finish('Produit modifié.');
  }

  Future<void> _editDepot() async {
    final item = await _select(title: 'Modifier un dépôt', values: widget.depots, label: (item) => item.name);
    if (item == null) return;
    final name = await _editText('Modifier le dépôt', item.name, 'Nom du dépôt');
    if (name == null || name.isEmpty) return;
    await widget.database.updateDepot(Depot(id: item.id, name: name, image: item.image));
    await _finish('Dépôt modifié.');
  }

  Future<void> _deleteDepot() async {
    final item = await _select(title: 'Supprimer un dépôt', values: widget.depots.where((item) => item.id != 'general-depot').toList(), label: (item) => item.name);
    if (item == null || !await _confirm('Ce dépôt sera supprimé. Vérifiez qu’aucun stock ou historique ne l’utilise encore.')) return;
    try {
      await widget.database.deleteDepot(item.id);
      await _finish('Dépôt supprimé.');
    } on StateError catch (error) {
      if (mounted) message(context, error.message);
    }
  }

  Future<void> _deleteMachine() async {
    final item = await _select(title: 'Supprimer une machine', values: widget.machines, label: (item) => item.name);
    if (item == null || !await _confirm('La machine sera supprimée. Les opérations restent dans l’historique.')) return;
    await widget.database.deleteMachine(item.id);
    await _finish('Machine supprimée.');
  }

  Future<void> _editMachine() async {
    final item = await _select(title: 'Modifier une machine', values: widget.machines, label: (item) => item.name);
    if (item == null) return;
    final name = await _editText('Modifier la machine', item.name, 'Nom de la machine');
    if (name == null || name.isEmpty) return;
    await widget.database.updateMachine(FactoryMachine(id: item.id, name: name, type: item.type, categoryId: item.categoryId, outputId: item.outputId, units: item.units, operatorIds: item.operatorIds, image: item.image, temporary: item.temporary, deadline: item.deadline, plannedPieces: item.plannedPieces, hopperPieces: item.hopperPieces, temporaryInputProductId: item.temporaryInputProductId, temporarySourceDepotId: item.temporarySourceDepotId, temporaryInputPieces: item.temporaryInputPieces));
    await _finish('Machine modifiée.');
  }

  Future<void> _deleteOperation() async {
    final item = await _select(title: 'Supprimer une opération', values: widget.operations, label: (item) => '${item.id} · ${item.pieces} pièce(s)');
    if (item == null || !await _confirm('Cette opération sera supprimée et sa réservation de stock sera annulée.')) return;
    await widget.database.deleteOperation(item.id);
    await _finish('Opération supprimée.');
  }

  Future<void> _editOperation() async {
    final item = await _select(title: 'Modifier une opération', values: widget.operations, label: (item) => '${item.id} · ${item.pieces} pièce(s)');
    if (item == null) return;
    final pieces = await _editPieces('Modifier la quantité réservée', item.pieces);
    if (pieces == null || pieces == 0) return;
    await widget.database.updateOperation(Operation(id: item.id, machineId: item.machineId, operatorId: item.operatorId, pieces: pieces, productId: item.productId, sourceDepotId: item.sourceDepotId, machineUnitNumber: item.machineUnitNumber, startedAt: item.startedAt, hopperPieces: item.hopperPieces, finishedAt: item.finishedAt, outputPieces: item.outputPieces, finalImage: item.finalImage, remainderImage: item.remainderImage, scrapImage: item.scrapImage, outputDepotId: item.outputDepotId, remainderDepotId: item.remainderDepotId, scrapDepotId: item.scrapDepotId, scrapProductId: item.scrapProductId, remainderPieces: item.remainderPieces, needsReview: item.needsReview, scrapPieces: item.scrapPieces, completionDraft: item.completionDraft, validatedAt: item.validatedAt, outputProductId: item.outputProductId, externalProduction: item.externalProduction));
    await _finish('Opération modifiée.');
  }

  Future<void> _deleteTransfer() async {
    final item = await _select(title: 'Supprimer un transfert', values: widget.transfers, label: (item) => '${item.pieces} pièce(s) · ${dateText(item.createdAt)}');
    if (item == null || !await _confirm('Ce transfert sera supprimé définitivement.')) return;
    await widget.database.deleteStockTransfer(item.id);
    await _finish('Transfert supprimé.');
  }

  Future<void> _editTransfer() async {
    final item = await _select(title: 'Modifier un transfert', values: widget.transfers, label: (item) => '${item.pieces} pièce(s) · ${dateText(item.createdAt)}');
    if (item == null) return;
    final pieces = await _editPieces('Modifier le transfert', item.pieces);
    if (pieces == null || pieces == 0) return;
    await widget.database.updateStockTransfer(StockTransfer(id: item.id, productId: item.productId, sourceDepotId: item.sourceDepotId, destinationDepotId: item.destinationDepotId, pieces: pieces, createdAt: item.createdAt, draft: item.draft));
    await _finish('Transfert modifié.');
  }

  Future<void> _deleteReturn() async {
    final item = await _select(title: 'Supprimer un retour client', values: widget.returns, label: (item) => '${item.pieces} pièce(s) · ${dateText(item.createdAt)}');
    if (item == null || !await _confirm('Ce retour sera supprimé définitivement.')) return;
    await widget.database.deleteSaleReturn(item.id);
    await _finish('Retour supprimé.');
  }

  Future<void> _editReturn() async {
    final item = await _select(title: 'Modifier un retour client', values: widget.returns, label: (item) => '${item.pieces} pièce(s) · ${dateText(item.createdAt)}');
    if (item == null) return;
    final pieces = await _editPieces('Modifier le retour', item.pieces);
    if (pieces == null || pieces == 0) return;
    await widget.database.updateSaleReturn(SaleReturn(id: item.id, saleId: item.saleId, productId: item.productId, depotId: item.depotId, pieces: pieces, createdAt: item.createdAt, status: item.status));
    await _finish('Retour modifié.');
  }

  Future<void> _adjustStock() async {
    Product? product;
    Depot? depot;
    final quantity = TextEditingController();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Correction exceptionnelle du stock'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            DropdownButtonFormField<Product>(
              isExpanded: true, decoration: const InputDecoration(labelText: 'Produit'),
              items: widget.products.map((item) => DropdownMenuItem(value: item, child: Text(item.name, overflow: TextOverflow.ellipsis))).toList(),
              onChanged: (value) => setDialogState(() => product = value),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<Depot>(
              isExpanded: true, decoration: const InputDecoration(labelText: 'Dépôt'),
              items: widget.depots.map((item) => DropdownMenuItem(value: item, child: Text(item.name))).toList(),
              onChanged: (value) => setDialogState(() => depot = value),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: quantity, keyboardType: const TextInputType.numberWithOptions(signed: true),
              decoration: const InputDecoration(labelText: 'Écart en pièces (+ ou -)'),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Enregistrer')),
          ],
        ),
      ),
    );
    final delta = int.tryParse(quantity.text);
    if (accepted != true || product == null || depot == null || delta == null || delta == 0) return;
    await widget.database.adjustStock(productId: product!.id, depotId: depot!.id, pieces: delta);
    await _finish('Correction de stock enregistrée.');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Aura(child: SafeArea(child: Page(child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.arrow_back, color: Colors.white)),
        const Text('Mode développeur', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: Colors.white)),
        const SizedBox(height: 6),
        const Text('Zone réservée au propriétaire. Modifiez ou supprimez tout élément ; les suppressions sont définitives.', style: TextStyle(color: Color(0xFFFEE2E2))),
        const SizedBox(height: 22),
        Glass(child: Column(children: [
          ListTile(leading: const Icon(Icons.tune_rounded, color: Color(0xFFB91C1C)), title: const Text('Corriger le stock'), subtitle: const Text('Ajoute ou retire un écart traçable.'), onTap: _adjustStock),
          const Divider(),
          ListTile(leading: const Icon(Icons.edit_outlined, color: AppPalette.primary), title: const Text('Modifier un produit'), onTap: _editProduct),
          const Divider(),
          ListTile(leading: const Icon(Icons.delete_forever_rounded, color: Color(0xFFB91C1C)), title: const Text('Supprimer un produit'), onTap: _deleteProduct),
          const Divider(),
          ListTile(leading: const Icon(Icons.edit_location_alt_outlined, color: AppPalette.primary), title: const Text('Modifier un dépôt'), onTap: _editDepot),
          const Divider(),
          ListTile(leading: const Icon(Icons.delete_sweep_outlined, color: Color(0xFFB91C1C)), title: const Text('Supprimer un dépôt'), onTap: _deleteDepot),
          const Divider(),
          ListTile(leading: const Icon(Icons.edit_outlined, color: AppPalette.primary), title: const Text('Modifier une catégorie'), onTap: _editCategory),
          const Divider(),
          ListTile(leading: const Icon(Icons.category_outlined, color: Color(0xFFB91C1C)), title: const Text('Supprimer une catégorie'), onTap: _deleteCategory),
          const Divider(),
          ListTile(leading: const Icon(Icons.shopping_cart_checkout_rounded, color: Color(0xFFB91C1C)), title: const Text('Supprimer un achat'), onTap: _deletePurchase),
          const Divider(),
          ListTile(leading: const Icon(Icons.edit_outlined, color: AppPalette.primary), title: const Text('Modifier un achat'), onTap: _editPurchase),
          const Divider(),
          ListTile(leading: const Icon(Icons.point_of_sale_rounded, color: Color(0xFFB91C1C)), title: const Text('Supprimer une vente'), onTap: _deleteSale),
          const Divider(),
          ListTile(leading: const Icon(Icons.edit_outlined, color: AppPalette.primary), title: const Text('Modifier une vente'), onTap: _editSale),
          const Divider(),
          ListTile(leading: const Icon(Icons.precision_manufacturing_outlined, color: Color(0xFFB91C1C)), title: const Text('Supprimer une machine'), onTap: _deleteMachine),
          const Divider(),
          ListTile(leading: const Icon(Icons.edit_outlined, color: AppPalette.primary), title: const Text('Modifier une machine'), onTap: _editMachine),
          const Divider(),
          ListTile(leading: const Icon(Icons.pending_actions_outlined, color: Color(0xFFB91C1C)), title: const Text('Supprimer une opération'), onTap: _deleteOperation),
          const Divider(),
          ListTile(leading: const Icon(Icons.edit_outlined, color: AppPalette.primary), title: const Text('Modifier une opération'), onTap: _editOperation),
          const Divider(),
          ListTile(leading: const Icon(Icons.swap_horiz_rounded, color: Color(0xFFB91C1C)), title: const Text('Supprimer un transfert'), onTap: _deleteTransfer),
          const Divider(),
          ListTile(leading: const Icon(Icons.edit_outlined, color: AppPalette.primary), title: const Text('Modifier un transfert'), onTap: _editTransfer),
          const Divider(),
          ListTile(leading: const Icon(Icons.assignment_return_outlined, color: Color(0xFFB91C1C)), title: const Text('Supprimer un retour client'), onTap: _deleteReturn),
          const Divider(),
          ListTile(leading: const Icon(Icons.edit_outlined, color: AppPalette.primary), title: const Text('Modifier un retour client'), onTap: _editReturn),
        ])),
      ],
    )))),
  );
}

class UsersPage extends StatefulWidget {
  const UsersPage({
    super.key,
    required this.users,
    required this.admin,
    required this.onAdd,
    required this.onUpdate,
    required this.onLoadSessions,
    required this.onOpenPayroll,
  });
  final List<AppUser> users;
  final bool admin;
  final Future<void> Function(AppUser) onAdd;
  final Future<void> Function(AppUser) onUpdate;
  final Future<List<UserSession>> Function(String) onLoadSessions;
  final VoidCallback onOpenPayroll;
  @override
  State<UsersPage> createState() => _UsersPageState();
}

class _UsersPageState extends State<UsersPage> {
  Future<void> add() async {
    final user = await Navigator.push<AppUser>(
      context,
      MaterialPageRoute(builder: (_) => const UserForm()),
    );
    if (user != null) {
      try {
        await widget.onAdd(user);
        if (mounted) setState(() {});
      } on StateError catch (error) {
        if (mounted) message(context, error.message);
      }
    }
  }

  Future<void> open(AppUser user) async {
    final changed = await Navigator.push<AppUser>(
      context,
      MaterialPageRoute(
        builder: (_) => UserDetailsPage(
          user: user,
          canManage: widget.admin,
          loadSessions: widget.onLoadSessions,
        ),
      ),
    );
    if (changed != null) {
      try {
        await widget.onUpdate(changed);
        if (mounted) setState(() {});
      } on StateError catch (error) {
        if (mounted) message(context, error.message);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final visibleUsers = widget.users.where((user) => !user.isPrivateOwner).toList();
    return Page(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHero(
          icon: Icons.groups_rounded,
          title: 'Équipe',
          subtitle: '${visibleUsers.length} membre(s) de l’atelier.',
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            const Expanded(
              child: Text(
                'Gérer les membres',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
              ),
            ),
            if (widget.admin) ...[
              OutlinedButton.icon(
                onPressed: widget.onOpenPayroll,
                icon: const Icon(Icons.payments_outlined),
                label: const Text('Paie'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: add,
                icon: const Icon(Icons.person_add_alt_1),
                label: const Text('Ajouter'),
              ),
            ],
          ],
        ),
        const SizedBox(height: 16),
        Glass(
          child: Column(
            children: visibleUsers
                .map(
                  (u) => ListTile(
                    onTap: () => open(u),
                    leading: CircleAvatar(
                      backgroundColor: const Color(0xFFE9D5FF),
                      foregroundColor: const Color(0xFF6B21A8),
                      child: Text(u.fullName.substring(0, 1).toUpperCase()),
                    ),
                    title: Text(
                      u.fullName,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    subtitle: Text('@${u.username} · ${u.status.label}'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                  ),
                )
                .toList(),
          ),
        ),
      ],
    ),
  );
  }
}

class DepotForm extends StatefulWidget {
  const DepotForm({super.key});
  @override
  State<DepotForm> createState() => _DepotFormState();
}

class StockTransferForm extends StatefulWidget {
  const StockTransferForm({
    super.key,
    required this.products,
    required this.depots,
    required this.available,
  });
  final List<Product> products;
  final List<Depot> depots;
  final int Function(String productId, String depotId) available;
  @override
  State<StockTransferForm> createState() => _StockTransferFormState();
}

class _StockTransferFormState extends State<StockTransferForm> {
  final form = GlobalKey<FormState>();
  final pieces = TextEditingController();
  String? productId;
  String? sourceDepotId;
  String? destinationDepotId;

  void save() {
    if (!(form.currentState?.validate() ?? false)) return;
    final quantity = int.tryParse(pieces.text) ?? 0;
    if (productId == null || sourceDepotId == null || destinationDepotId == null ||
        sourceDepotId == destinationDepotId || quantity <= 0 ||
        quantity > widget.available(productId!, sourceDepotId!)) {
      message(context, 'Vérifiez les dépôts et la quantité disponible.');
      return;
    }
    Navigator.pop(
      context,
      StockTransfer(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        productId: productId!,
        sourceDepotId: sourceDepotId!,
        destinationDepotId: destinationDepotId!,
        pieces: quantity,
        createdAt: DateTime.now(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => FormShell(
    title: 'Transférer le stock',
    subtitle: 'Le transfert reste en brouillon jusqu’à sa validation.',
    child: Form(
      key: form,
      child: Column(
        children: [
          DropdownButtonFormField<String>(
            initialValue: productId,
            decoration: const InputDecoration(labelText: 'Produit *'),
            items: widget.products.map((item) => DropdownMenuItem(value: item.id, child: Text(item.name))).toList(),
            onChanged: (value) => setState(() => productId = value),
            validator: (value) => value == null ? 'Choisissez un produit.' : null,
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: sourceDepotId,
            decoration: const InputDecoration(labelText: 'Dépôt de départ *'),
            items: widget.depots.map((item) => DropdownMenuItem(value: item.id, child: Text(item.name))).toList(),
            onChanged: (value) => setState(() => sourceDepotId = value),
            validator: (value) => value == null ? 'Choisissez le dépôt de départ.' : null,
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: destinationDepotId,
            decoration: const InputDecoration(labelText: 'Dépôt d’arrivée *'),
            items: widget.depots.map((item) => DropdownMenuItem(value: item.id, child: Text(item.name))).toList(),
            onChanged: (value) => setState(() => destinationDepotId = value),
            validator: (value) => value == null ? 'Choisissez le dépôt d’arrivée.' : null,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: pieces,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              labelText: 'Quantité (pièces) *',
              helperText: productId != null && sourceDepotId != null
                  ? 'Disponible : ${widget.available(productId!, sourceDepotId!)} pièce(s)'
                  : null,
            ),
            validator: (value) => (int.tryParse(value ?? '') ?? 0) > 0 ? null : 'Indiquez une quantité valide.',
          ),
          const SizedBox(height: 20),
          SizedBox(width: double.infinity, child: FilledButton.icon(
            onPressed: save,
            icon: const Icon(Icons.send_rounded),
            label: const Text('Envoyer à la validation'),
          )),
        ],
      ),
    ),
  );
}

class _DepotFormState extends State<DepotForm> {
  final form = GlobalKey<FormState>();
  final name = TextEditingController();
  Uint8List? image;

  Future<void> pick() async {
    final file = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 82,
      maxWidth: 1600,
    );
    if (file != null) {
      final bytes = await file.readAsBytes();
      if (mounted) setState(() => image = bytes);
    }
  }

  void save() {
    if (!(form.currentState?.validate() ?? false)) return;
    Navigator.pop(
      context,
      Depot(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        name: name.text.trim(),
        image: image,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => FormShell(
    title: 'Ajouter un dépôt',
    child: Form(
      key: form,
      child: Column(
        children: [
          TextFormField(
            controller: name,
            decoration: const InputDecoration(labelText: 'Nom du dépôt *'),
            validator: required,
          ),
          const SizedBox(height: 14),
          ImageInput(bytes: image, label: 'Photo du dépôt (facultatif)', onTap: pick),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FilledButton(onPressed: save, child: const Text('Enregistrer le dépôt')),
          ),
        ],
      ),
    ),
  );
}

class ProductKindPage extends StatelessWidget {
  const ProductKindPage({super.key});

  @override
  Widget build(BuildContext context) => FormShell(
    title: 'Type de produit',
    subtitle: 'Choisissez le type avant de renseigner le produit.',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: ProductKind.values
          .map(
            (kind) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: InkWell(
                borderRadius: BorderRadius.circular(18),
                onTap: () => Navigator.pop(context, kind),
                child: Glass(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Icon(
                        switch (kind) {
                          ProductKind.standard => Icons.inventory_2_outlined,
                          ProductKind.hose => Icons.water_drop_outlined,
                          ProductKind.manufactured => Icons.precision_manufacturing_outlined,
                          ProductKind.diameter => Icons.architecture_outlined,
                        },
                        color: AppPalette.primary,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(kind.label, style: const TextStyle(fontWeight: FontWeight.w900)),
                            const SizedBox(height: 4),
                            Text(kind.description, style: const TextStyle(color: AppPalette.muted, fontSize: 12)),
                          ],
                        ),
                      ),
                      const Icon(Icons.chevron_right_rounded),
                    ],
                  ),
                ),
              ),
            ),
          )
          .toList(),
    ),
  );
}

class ProductForm extends StatefulWidget {
  const ProductForm({
    super.key,
    required this.kind,
    required this.depots,
    required this.categories,
  });
  final ProductKind kind;
  final List<Depot> depots;
  final List<ProductCategory> categories;

  @override
  State<ProductForm> createState() => _ProductFormState();
}

class _ProductFormState extends State<ProductForm> {
  final form = GlobalKey<FormState>();
  final name = TextEditingController();
  final reference = TextEditingController();
  final length = TextEditingController();
  final width = TextEditingController();
  final metersPerPiece = TextEditingController();
  final thickness = TextEditingController();
  final diameter = TextEditingController();
  final initialStock = TextEditingController(text: '0');
  Uint8List? image;
  String? initialDepotId;
  String? categoryId;
  MaterialType material = MaterialType.steel;
  LengthUnit lengthUnit = LengthUnit.meter;
  LengthUnit widthUnit = LengthUnit.meter;
  ThicknessUnit thicknessUnit = ThicknessUnit.millimeter;
  HoseUnit hoseUnit = HoseUnit.piece;

  bool get isManufactured => widget.kind == ProductKind.manufactured;
  bool get hasStandardMeasurements => widget.kind == ProductKind.standard;
  bool get isHose => widget.kind == ProductKind.hose;
  bool get isDiameterBased => widget.kind == ProductKind.diameter;
  double get lengthMeters => isHose
      ? (hoseUnit == HoseUnit.piece ? number(metersPerPiece.text) : 1)
      : number(length.text) * lengthUnit.metres;
  double get widthMeters => number(width.text) * widthUnit.metres;
  double get thicknessMillimetres =>
      number(thickness.text) * thicknessUnit.millimetres;
  double get estimatedKilograms => kilogramsForDimensions(
    widthMeters: widthMeters,
    lengthMeters: lengthMeters,
    thicknessMillimetres: thicknessMillimetres,
    densityKilogramsPerCubicMeter: material.density,
  );
  double? get calculatedDiameter {
    final enteredLength = number(length.text);
    return enteredLength > 0 ? enteredLength / 3.14 : null;
  }

  Future<void> pick() async {
    final file = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 82,
      maxWidth: 1600,
    );
    if (file != null) {
      final bytes = await file.readAsBytes();
      if (mounted) setState(() => image = bytes);
    }
  }

  void save() {
    if (!(form.currentState?.validate() ?? false) || image == null) {
      message(context, 'Ajoutez une photo et remplissez les champs obligatoires.');
      return;
    }
    Navigator.pop(
      context,
      ProductCreation(
        categoryId: isManufactured ? null : categoryId,
        product: Product(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          name: name.text.trim(),
          reference: reference.text.trim(),
          width: hasStandardMeasurements ? widthMeters : 1.5,
          lengthMeters: lengthMeters,
          lengthUnit: isHose ? LengthUnit.meter : lengthUnit,
          thickness: hasStandardMeasurements ? thicknessMillimetres : 0,
          kind: widget.kind,
          hoseUnit: hoseUnit,
          metersPerPiece: isHose && hoseUnit == HoseUnit.piece
              ? lengthMeters
              : null,
          diameter: isDiameterBased ? number(diameter.text) : null,
          initialStock: int.parse(initialStock.text),
          initialDepotId: initialDepotId ?? 'general-depot',
          material: isHose ? MaterialType.pvc : material,
          image: image,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => FormShell(
    title: 'Ajouter un produit',
    subtitle: widget.kind.label,
    child: Form(
      key: form,
      child: Column(
        children: [
          TextFormField(
            controller: name,
            decoration: const InputDecoration(labelText: 'Nom du produit *'),
            validator: required,
          ),
          const SizedBox(height: 14),
          TextFormField(
            controller: reference,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(labelText: 'Référence (facultatif)'),
          ),
          const SizedBox(height: 14),
          ImageInput(bytes: image, label: 'Photo du produit *', onTap: pick),
          const SizedBox(height: 14),
          if (isHose) ...[
            const Align(
              alignment: Alignment.centerLeft,
              child: Text('Unité du tuyau *', style: TextStyle(fontWeight: FontWeight.w900)),
            ),
            const SizedBox(height: 8),
            SegmentedButton<HoseUnit>(
              segments: const [
                ButtonSegment(value: HoseUnit.piece, label: Text('Pièce')),
                ButtonSegment(value: HoseUnit.meter, label: Text('Mètre')),
              ],
              selected: {hoseUnit},
              onSelectionChanged: (value) => setState(() => hoseUnit = value.first),
            ),
            const SizedBox(height: 12),
            if (hoseUnit == HoseUnit.piece) ...[
              TextFormField(
                controller: metersPerPiece,
                decoration: const InputDecoration(
                  labelText: 'Mètres dans chaque pièce *',
                ),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                validator: positive,
              ),
              const SizedBox(height: 12),
            ],
            Glass(
              padding: const EdgeInsets.all(14),
              child: Text(
                hoseUnit == HoseUnit.piece
                    ? 'Indiquez les mètres dans chaque pièce. Le stock initial sera saisi en pièces et le total en mètres sera calculé automatiquement.'
                    : 'Le stock initial de ce tuyau sera saisi directement en mètres.',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ]
          else if (isDiameterBased) ...[
            TextFormField(
              controller: diameter,
              decoration: const InputDecoration(labelText: 'Diamètre (mm) *'),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              validator: positive,
            ),
            const SizedBox(height: 12),
            const Glass(
              padding: EdgeInsets.all(14),
              child: Text(
                'Les forets et produits par diamètre n’ont pas besoin des mesures habituelles et ne peuvent pas être utilisés par une machine.',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ] else if (isManufactured) ...[
            const Glass(
              padding: EdgeInsets.all(14),
              child: Text(
                'Ce produit est un modèle de fabrication. Il ne demande ni longueur, ni largeur, ni épaisseur : chaque production créera automatiquement une variante avec les mesures du produit brut choisi par l’opérateur.',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ] else ...[
            const Align(
              alignment: Alignment.centerLeft,
              child: Text('Matière du produit *', style: TextStyle(fontWeight: FontWeight.w900)),
            ),
            const SizedBox(height: 8),
            SegmentedButton<MaterialType>(
              segments: const [
                ButtonSegment(value: MaterialType.steel, label: Text('Fer / acier')),
                ButtonSegment(value: MaterialType.pvc, label: Text('PVC')),
              ],
              selected: {material},
              onSelectionChanged: (value) => setState(() => material = value.first),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: width,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(labelText: 'Largeur *'),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    validator: positive,
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 112,
                  child: DropdownButtonFormField<LengthUnit>(
                    initialValue: widthUnit,
                    decoration: const InputDecoration(labelText: 'Unité'),
                    items: LengthUnit.values
                        .map((unit) => DropdownMenuItem(value: unit, child: Text(unit.label)))
                        .toList(),
                    onChanged: (unit) => setState(() => widthUnit = unit!),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: length,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(labelText: 'Longueur *'),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    validator: positive,
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 112,
                  child: DropdownButtonFormField<LengthUnit>(
                    initialValue: lengthUnit,
                    decoration: const InputDecoration(labelText: 'Unité'),
                    items: LengthUnit.values
                        .map((unit) => DropdownMenuItem(value: unit, child: Text(unit.label)))
                        .toList(),
                    onChanged: (unit) => setState(() => lengthUnit = unit!),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: thickness,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(labelText: 'Épaisseur *'),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    validator: positive,
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 112,
                  child: DropdownButtonFormField<ThicknessUnit>(
                    initialValue: thicknessUnit,
                    decoration: const InputDecoration(labelText: 'Unité'),
                    items: ThicknessUnit.values
                        .map((unit) => DropdownMenuItem(value: unit, child: Text(unit.label)))
                        .toList(),
                    onChanged: (unit) => setState(() => thicknessUnit = unit!),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Glass(
              padding: const EdgeInsets.all(14),
              child: Text(
                calculatedDiameter == null
                    ? 'Résultat du diamètre : renseignez une longueur pour lancer le calcul.\n'
                        'Formule : longueur ÷ 3,14'
                    : 'Résultat du diamètre : Ø ${formatNumber(calculatedDiameter!)} ${lengthUnit.label}\n'
                        'Calcul : ${formatNumber(number(length.text))} ${lengthUnit.label} ÷ 3,14',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(height: 12),
            Glass(
              padding: const EdgeInsets.all(14),
              child: Text(
                'Dimensions converties : ${formatNumber(number(length.text))} ${lengthUnit.label} = ${formatNumber(lengthMeters)} m · '
                '${formatNumber(number(width.text))} ${widthUnit.label} = ${formatNumber(widthMeters)} m · '
                '${formatNumber(number(thickness.text))} ${thicknessUnit.label} = ${formatNumber(thicknessMillimetres)} mm\n'
                'Poids estimé : ${formatWeight(estimatedKilograms)} / pièce\n'
                'Le cm, le mm et le m sont des dimensions ; le kg est le résultat du poids.',
              ),
            ),
          ],
          const SizedBox(height: 12),
          if (!isManufactured) ...[
            DropdownButtonFormField<String>(
              initialValue: categoryId,
              decoration: const InputDecoration(labelText: 'Catégorie *'),
              items: widget.categories
                  .map((category) => DropdownMenuItem(value: category.id, child: Text(category.name)))
                  .toList(),
              onChanged: (value) => setState(() => categoryId = value),
              validator: (value) => value == null ? 'Choisissez une catégorie.' : null,
            ),
            const SizedBox(height: 12),
          ],
          TextFormField(
            controller: initialStock,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              labelText: isHose && hoseUnit == HoseUnit.meter
                  ? 'Stock initial (mètres) *'
                  : 'Stock initial (pièces) *',
              helperText: isManufactured
                  ? 'Quantité déjà disponible avant les nouvelles productions.'
                  : null,
            ),
            validator: (value) {
              final count = int.tryParse(value ?? '');
              return count == null || count < 0
                  ? 'Indiquez une quantité valide.'
                  : null;
            },
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: initialDepotId,
            decoration: const InputDecoration(labelText: 'Dépôt du stock initial *'),
            items: widget.depots
                .map(
                  (depot) => DropdownMenuItem(
                    value: depot.id,
                    child: Text(depot.name),
                  ),
                )
                .toList(),
            onChanged: (value) => setState(() => initialDepotId = value),
            validator: (value) => value == null ? 'Choisissez un dépôt.' : null,
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: save,
              child: const Text('Enregistrer le produit'),
            ),
          ),
        ],
      ),
    ),
  );
}

class StockForm extends StatefulWidget {
  const StockForm({
    super.key,
    required this.products,
    required this.stock,
    required this.depots,
    required this.suppliers,
    required this.onAddSupplier,
    this.initialProductId,
  });
  final List<Product> products;
  final int Function(String) stock;
  final List<Depot> depots;
  final List<Supplier> suppliers;
  final Future<Supplier?> Function() onAddSupplier;
  final String? initialProductId;

  @override
  State<StockForm> createState() => _StockFormState();
}

class SupplierForm extends StatefulWidget {
  const SupplierForm({super.key});

  @override
  State<SupplierForm> createState() => _SupplierFormState();
}

class _SupplierFormState extends State<SupplierForm> {
  final form = GlobalKey<FormState>();
  final name = TextEditingController();
  final company = TextEditingController();
  final contact = TextEditingController();
  final images = <Uint8List>[];

  Future<void> pickImages() async {
    final available = 10 - images.length;
    if (available <= 0) return message(context, 'Maximum : 10 photos.');
    final picked = await ImagePicker().pickMultiImage(imageQuality: 82, maxWidth: 1600);
    if (picked.isEmpty) return;
    final bytes = await Future.wait(picked.take(available).map((file) => file.readAsBytes()));
    if (mounted) setState(() => images.addAll(bytes));
    if (picked.length > available && mounted) {
      message(context, 'Maximum : 10 photos.');
    }
  }

  void save() {
    if (!(form.currentState?.validate() ?? false)) return;
    Navigator.pop(
      context,
      Supplier(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        name: name.text.trim(),
        company: company.text.trim(),
        contact: contact.text.trim(),
        images: images,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => FormShell(
    title: 'Ajouter un fournisseur',
    child: Form(
      key: form,
      child: Column(
        children: [
          TextFormField(
            controller: name,
            decoration: const InputDecoration(labelText: 'Nom du fournisseur *'),
            validator: required,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: company,
            decoration: const InputDecoration(hintText: 'Société', labelText: 'Nom de société'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: contact,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(labelText: 'Contact (facultatif)'),
          ),
          const SizedBox(height: 12),
          MultiImageInput(
            images: images,
            label: 'Photos du fournisseur (${images.length}/10)',
            onTap: pickImages,
            onRemove: (index) => setState(() => images.removeAt(index)),
          ),
          const SizedBox(height: 20),
          SizedBox(width: double.infinity, child: FilledButton(onPressed: save, child: const Text('Enregistrer le fournisseur'))),
        ],
      ),
    ),
  );
}

class ClientForm extends StatefulWidget {
  const ClientForm({super.key});

  @override
  State<ClientForm> createState() => _ClientFormState();
}

class _ClientFormState extends State<ClientForm> {
  final form = GlobalKey<FormState>();
  final name = TextEditingController();
  final company = TextEditingController();
  final phone = TextEditingController();
  final ice = TextEditingController();
  final images = <Uint8List>[];

  Future<void> pickImages() async {
    final available = 10 - images.length;
    if (available <= 0) return message(context, 'Maximum : 10 photos.');
    final picked = await ImagePicker().pickMultiImage(imageQuality: 82, maxWidth: 1600);
    if (picked.isEmpty) return;
    final bytes = await Future.wait(picked.take(available).map((file) => file.readAsBytes()));
    if (mounted) setState(() => images.addAll(bytes));
    if (picked.length > available && mounted) message(context, 'Maximum : 10 photos.');
  }

  void save() {
    if (name.text.trim().isEmpty && company.text.trim().isEmpty) {
      message(context, 'Indiquez au moins le nom ou la société du client.');
      return;
    }
    Navigator.pop(
      context,
      Client(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        name: name.text.trim(),
        company: company.text.trim(),
        phone: phone.text.trim(),
        ice: ice.text.trim(),
        images: images,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => FormShell(
    title: 'Ajouter un client',
    child: Form(
      key: form,
      child: Column(
        children: [
          TextFormField(
            controller: name,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: 'Nom'),
          ),
          if (name.text.trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            TextField(
              controller: phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(labelText: 'N° de téléphone (facultatif)'),
            ),
          ],
          const SizedBox(height: 12),
          TextFormField(
            controller: company,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(hintText: 'Société', labelText: 'Nom de société'),
          ),
          if (company.text.trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            TextField(
              controller: ice,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'ICE (facultatif)'),
            ),
          ],
          const SizedBox(height: 12),
          MultiImageInput(
            images: images,
            label: 'Photos du client (${images.length}/10)',
            onTap: pickImages,
            onRemove: (index) => setState(() => images.removeAt(index)),
          ),
          const SizedBox(height: 20),
          SizedBox(width: double.infinity, child: FilledButton(onPressed: save, child: const Text('Enregistrer le client'))),
        ],
      ),
    ),
  );
}

class SaleForm extends StatefulWidget {
  const SaleForm({
    super.key,
    required this.products,
    required this.depots,
    required this.clients,
    required this.available,
    required this.onAddClient,
  });
  final List<Product> products;
  final List<Depot> depots;
  final List<Client> clients;
  final int Function(String, String) available;
  final Future<Client?> Function() onAddClient;

  @override
  State<SaleForm> createState() => _SaleFormState();
}

class _SaleFormState extends State<SaleForm> {
  String? productId;
  String? openedProductFamilyId;
  String? depotId;
  String? clientId;
  final quantity = TextEditingController();
  final images = <Uint8List>[];
  InventoryUnit unit = InventoryUnit.piece;

  Product? get selectedProduct {
    for (final product in widget.products) {
      if (product.id == productId) return product;
    }
    return null;
  }

  Product? get openedProductFamily {
    for (final product in widget.products) {
      if (product.id == openedProductFamilyId) return product;
    }
    return null;
  }

  List<Product> get visibleProducts => openedProductFamilyId == null
      ? widget.products.where((product) => !product.isManufacturedVariant).toList()
      : widget.products
          .where((product) => product.parentProductId == openedProductFamilyId)
          .toList();

  List<Product> derivedFrom(Product product) => widget.products
      .where((item) => item.parentProductId == product.id)
      .toList();

  void chooseProduct(Product product) {
    final variants = derivedFrom(product);
    if (openedProductFamilyId == null && variants.isNotEmpty) {
      setState(() {
        // Selecting a manufactured base product is navigation, not a sale:
        // only one of its actual dimensions can be sold.
        openedProductFamilyId = product.id;
        productId = null;
        depotId = null;
        quantity.clear();
      });
      return;
    }
    setState(() {
      productId = product.id;
      depotId = null;
      if (product.isHose) {
        unit = product.hoseManagedByMeter
            ? InventoryUnit.meter
            : InventoryUnit.piece;
      }
    });
  }

  int get pieces => selectedProduct == null
      ? 0
      : piecesForQuantity(selectedProduct!, number(quantity.text), unit);

  List<InventoryUnit> get availableUnits {
    final product = selectedProduct;
    if (product?.isHose != true) return InventoryUnit.values;
    return product!.hoseManagedByMeter
        ? const [InventoryUnit.meter]
        : const [InventoryUnit.piece];
  }

  Future<void> addClient() async {
    final added = await widget.onAddClient();
    if (added != null && mounted) setState(() => clientId = added.id);
  }

  Future<void> pickImages() async {
    final available = 10 - images.length;
    if (available <= 0) return message(context, 'Maximum : 10 photos.');
    final picked = await ImagePicker().pickMultiImage(imageQuality: 82, maxWidth: 1600);
    if (picked.isEmpty) return;
    final bytes = await Future.wait(picked.take(available).map((file) => file.readAsBytes()));
    if (mounted) setState(() => images.addAll(bytes));
  }

  void save() {
    final entered = number(quantity.text);
    if (productId == null || depotId == null || clientId == null || entered <= 0 || pieces <= 0) {
      return message(context, 'Choisissez un client, un produit, un dépôt et une quantité valide.');
    }
    if (pieces > widget.available(productId!, depotId!)) {
      return message(context, 'La quantité demandée dépasse le stock disponible dans ce dépôt.');
    }
    Navigator.pop(
      context,
      Sale(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        productId: productId!,
        depotId: depotId!,
        clientId: clientId!,
        pieces: pieces,
        quantity: entered,
        unit: unit,
        images: images,
        createdAt: DateTime.now(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => FormShell(
    title: 'Vente',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: clientId,
                decoration: const InputDecoration(labelText: 'Client *'),
                items: widget.clients
                    .map((client) => DropdownMenuItem(
                      value: client.id,
                      child: Text(client.company.isEmpty ? client.name : '${client.name.isEmpty ? 'Client' : client.name} · ${client.company}'),
                    ))
                    .toList(),
                onChanged: (value) => setState(() => clientId = value),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(onPressed: addClient, icon: const Icon(Icons.person_add_alt_1_rounded), tooltip: 'Ajouter un client'),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(child: Text(openedProductFamily == null ? 'Produit à vendre *' : 'Dimensions de ${openedProductFamily!.name}', style: const TextStyle(fontWeight: FontWeight.w900))),
            if (openedProductFamily != null)
              TextButton.icon(
                onPressed: () => setState(() {
                  openedProductFamilyId = null;
                  productId = null;
                  depotId = null;
                  quantity.clear();
                }),
                icon: const Icon(Icons.arrow_back),
                label: const Text('Produits'),
              ),
          ],
        ),
        const SizedBox(height: 8),
        ProductPicker(
          products: visibleProducts,
          selected: productId == null ? <String>{} : {productId!},
          onTap: chooseProduct,
        ),
        if (productId != null) ...[
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: depotId,
            decoration: const InputDecoration(labelText: 'Dépôt de sortie *'),
            items: widget.depots.map((depot) => DropdownMenuItem(
              value: depot.id,
              child: Text(
                '${depot.name} (${productQuantityLabel(selectedProduct!, widget.available(productId!, depot.id))})',
              ),
            )).toList(),
            onChanged: (value) => setState(() => depotId = value),
          ),
        ],
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: quantity,
                onChanged: (_) => setState(() {}),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: selectedProduct?.isHose == true
                    ? [FilteringTextInputFormatter.digitsOnly]
                    : null,
                decoration: InputDecoration(
                  labelText: selectedProduct?.isHose == true
                      ? selectedProduct!.hoseManagedByMeter
                          ? 'Longueur vendue (m) *'
                          : 'Pièces vendues *'
                      : 'Quantité vendue *',
                ),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 145,
              child: DropdownButtonFormField<InventoryUnit>(
                initialValue: unit,
                decoration: const InputDecoration(labelText: 'Unité'),
                items: availableUnits
                    .map((value) => DropdownMenuItem(value: value, child: Text(value.label)))
                    .toList(),
                onChanged: selectedProduct?.isHose == true
                    ? null
                    : (value) => setState(() => unit = value!),
              ),
            ),
          ],
        ),
        if (selectedProduct != null && number(quantity.text) > 0)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              selectedProduct?.hoseManagedByMeter == true
                  ? 'Sortie de stock : $pieces mètre(s)'
                  : selectedProduct?.isHose == true
                  ? 'Sortie de stock : $pieces pièce(s) = ${formatNumber(pieces * selectedProduct!.lengthMeters)} m'
                  : 'Sortie de stock : $pieces pièce(s)',
              style: const TextStyle(color: Color(0xFF725280), fontWeight: FontWeight.w700),
            ),
          ),
        const SizedBox(height: 12),
        MultiImageInput(
          images: images,
          label: 'Photos des pièces / accessoires (${images.length}/10)',
          onTap: pickImages,
          onRemove: (index) => setState(() => images.removeAt(index)),
        ),
        const SizedBox(height: 20),
        SizedBox(width: double.infinity, child: FilledButton.icon(onPressed: save, icon: const Icon(Icons.point_of_sale_rounded), label: const Text('Enregistrer la vente'))),
      ],
    ),
  );
}

class _StockFormState extends State<StockForm> {
  String? selected;
  String? depotId;
  String? supplierId;
  final pieces = TextEditingController();
  final receiptNumber = TextEditingController();
  final images = <Uint8List>[];
  InventoryUnit unit = InventoryUnit.piece;

  Product? get selectedProduct {
    for (final product in widget.products) {
      if (product.id == selected) return product;
    }
    return null;
  }

  double get enteredQuantity => number(pieces.text);
  int get addedPieces => selectedProduct == null
      ? 0
      : piecesForQuantity(selectedProduct!, enteredQuantity, unit);

  List<InventoryUnit> get availableUnits {
    final product = selectedProduct;
    if (product?.isHose != true) return InventoryUnit.values;
    return product!.hoseManagedByMeter
        ? const [InventoryUnit.meter]
        : const [InventoryUnit.piece];
  }

  Future<void> addSupplier() async {
    final added = await widget.onAddSupplier();
    if (added != null && mounted) setState(() => supplierId = added.id);
  }

  Future<void> pickImages() async {
    final available = 10 - images.length;
    if (available <= 0) {
      message(context, 'Vous pouvez ajouter au maximum 10 photos.');
      return;
    }
    final picked = await ImagePicker().pickMultiImage(
      imageQuality: 82,
      maxWidth: 1600,
    );
    if (picked.isEmpty) return;
    final newImages = await Future.wait(picked.take(available).map((file) => file.readAsBytes()));
    if (mounted) setState(() => images.addAll(newImages));
    if (picked.length > available && mounted) {
      message(context, 'Seules $available photo(s) ont été ajoutées (maximum : 10).');
    }
  }

  @override
  void initState() {
    super.initState();
    if (widget.products.any((product) => product.id == widget.initialProductId)) {
      selected = widget.initialProductId;
      if (selectedProduct?.isHose == true) {
        unit = selectedProduct!.hoseManagedByMeter
            ? InventoryUnit.meter
            : InventoryUnit.piece;
      }
    }
  }

  void save() {
    final count = addedPieces;
    if (selected == null ||
        depotId == null ||
        count <= 0 ||
        supplierId == null ||
        receiptNumber.text.trim().isEmpty) {
      message(
        context,
        'Choisissez un produit, un fournisseur, un dépôt, une quantité valide et le n° de bon.',
      );
      return;
    }
    Navigator.pop(
      context,
      StockAddition(
        productId: selected!,
        depotId: depotId!,
        pieces: count,
        receiptNumber: receiptNumber.text.trim(),
        supplierId: supplierId,
        quantity: enteredQuantity,
        unit: unit,
        images: images,
        addedAt: DateTime.now(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => FormShell(
    title: 'Achat · Ajouter au stock',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Choisissez un produit',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 10),
        ProductPicker(
          products: widget.products,
          selected: selected == null ? <String>{} : <String>{selected!},
          onTap: (product) => setState(() {
            selected = product.id;
            if (product.isHose) {
              unit = product.hoseManagedByMeter
                  ? InventoryUnit.meter
                  : InventoryUnit.piece;
            }
          }),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: supplierId,
                decoration: const InputDecoration(labelText: 'Fournisseur *'),
                items: widget.suppliers
                    .map((supplier) => DropdownMenuItem(
                      value: supplier.id,
                      child: Text(supplier.company.isEmpty ? supplier.name : '${supplier.name} · ${supplier.company}'),
                    ))
                    .toList(),
                onChanged: (value) => setState(() => supplierId = value),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              onPressed: addSupplier,
              tooltip: 'Ajouter un fournisseur',
              icon: const Icon(Icons.person_add_alt_1_rounded),
            ),
          ],
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: depotId,
          decoration: const InputDecoration(labelText: 'Dépôt de destination *'),
          items: widget.depots
              .map((depot) => DropdownMenuItem(value: depot.id, child: Text(depot.name)))
              .toList(),
          onChanged: (value) => setState(() => depotId = value),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: receiptNumber,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(labelText: 'N° de bon *'),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: pieces,
                onChanged: (_) => setState(() {}),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: selectedProduct?.isHose == true
                    ? [FilteringTextInputFormatter.digitsOnly]
                    : null,
                decoration: InputDecoration(
                  labelText: selectedProduct?.isHose == true
                      ? selectedProduct!.hoseManagedByMeter
                          ? 'Longueur à ajouter (m) *'
                          : 'Nombre de pièces à ajouter *'
                      : 'Quantité achetée *',
                ),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 145,
              child: DropdownButtonFormField<InventoryUnit>(
                initialValue: unit,
                decoration: const InputDecoration(labelText: 'Unité'),
                items: availableUnits
                    .map((value) => DropdownMenuItem(value: value, child: Text(value.label)))
                    .toList(),
                onChanged: selectedProduct?.isHose == true
                    ? null
                    : (value) => setState(() => unit = value!),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        MultiImageInput(
          images: images,
          label: 'Photos des pièces / accessoires (${images.length}/10)',
          onTap: pickImages,
          onRemove: (index) => setState(() => images.removeAt(index)),
        ),
        if (selectedProduct != null) ...[
          const SizedBox(height: 16),
          Glass(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Résumé de l’ajout',
                  style: TextStyle(fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 8),
                Text(
                  selectedProduct!.hoseManagedByMeter
                      ? 'Entrée : +$addedPieces mètre(s)'
                      : selectedProduct!.isHose
                      ? 'Entrée : +$addedPieces pièce(s) = ${formatNumber(addedPieces * selectedProduct!.lengthMeters)} m'
                      : 'Entrée : +${formatQuantity(enteredQuantity, unit)} · équivaut à $addedPieces pièce(s)',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 4),
                if (!selectedProduct!.isHose)
                  Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE9D5FF),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    'Le stock est conservé en pièces : ${formatQuantity(enteredQuantity, unit)} est converti en $addedPieces pièce(s) pour ce produit.',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF45116C),
                    ),
                  ),
                ),
                if (!selectedProduct!.isHose) const SizedBox(height: 4),
                if (!selectedProduct!.isHose)
                  Text(
                    'Stock après ajout : ${formatWeight((widget.stock(selectedProduct!.id) + addedPieces) * selectedProduct!.kilogramsPerPiece)}',
                  ),
                const SizedBox(height: 4),
                Text(
                  '${productQuantityLabel(selectedProduct!, widget.stock(selectedProduct!.id) + addedPieces)} au total',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF725280),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: save,
            child: const Text('Ajouter au stock'),
          ),
        ),
      ],
    ),
  );
}

class MachineForm extends StatefulWidget {
  const MachineForm({
    super.key,
    required this.categories,
    required this.products,
    required this.users,
    required this.onUserAdded,
    required this.canManageUsers,
    required this.canCreateTemporary,
    required this.depots,
    required this.available,
  });
  final List<ProductCategory> categories;
  final List<Product> products;
  final List<AppUser> users;
  final Future<void> Function(AppUser) onUserAdded;
  final bool canManageUsers;
  final bool canCreateTemporary;
  final List<Depot> depots;
  final int Function(String, String) available;
  @override
  State<MachineForm> createState() => _MachineFormState();
}

class _MachineFormState extends State<MachineForm> {
  final form = GlobalKey<FormState>();
  final name = TextEditingController();
  final copies = TextEditingController(text: '1');
  final plannedPieces = TextEditingController();
  final temporaryInputPieces = TextEditingController();
  final hopperPieces = TextEditingController();
  final operators = <String>{};
  String? categoryId;
  String? outputId;
  String? temporaryInputProductId;
  String? temporarySourceDepotId;
  List<Uint8List?> unitImages = [null];
  MachineType type = MachineType.standard;
  bool temporary = false;
  DateTime? deadline;

  List<Product> get manufacturedProducts =>
      widget.products
          .where((product) => product.isManufacturedTemplate)
          .toList();

  List<Product> get temporaryMaterials => widget.products
      .where((product) =>
          product.canBeUsedInMachine &&
          (widget.categories
                  .where((category) => category.id == categoryId)
                  .expand((category) => category.productIds)
                  .contains(product.id)))
      .toList();

  void syncUnitImages() {
    final count = int.tryParse(copies.text) ?? 1;
    unitImages = List.generate(count, (index) => index < unitImages.length ? unitImages[index] : null);
  }

  Future<void> pickUnitImage(int index) async {
    final file = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 82,
      maxWidth: 1600,
    );
    if (file != null) {
      final bytes = await file.readAsBytes();
      if (mounted) setState(() => unitImages[index] = bytes);
    }
  }

  Future<void> selectDeadline() async {
    final value = await showDatePicker(
      context: context,
      initialDate: deadline ?? DateTime.now(),
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 3650)),
    );
    if (value != null && mounted) setState(() => deadline = value);
  }

  Future<void> addUser() async {
    if (!widget.canManageUsers) return;
    final user = await Navigator.push<AppUser>(
      context,
      MaterialPageRoute(builder: (_) => const UserForm()),
    );
    if (user != null && mounted) {
      await widget.onUserAdded(user);
      if (!mounted) return;
      if (!user.isOperator) {
        message(context, 'Seul un utilisateur avec le rôle Opérateur peut être affecté à une machine.');
        return;
      }
      setState(() {
        operators.add(user.id);
      });
    }
  }

  void save() {
    if (!(form.currentState?.validate() ?? false)) return;
    syncUnitImages();
    final missing = <String>[
      if (!temporary && unitImages.any((image) => image == null)) 'photo de chaque exemplaire',
      if (categoryId == null) 'catégorie',
      if (outputId == null) 'produit fabriqué',
      if (!temporary && operators.isEmpty) 'opérateur',
      if (temporary && deadline == null) 'date de fin',
      if (temporary && (int.tryParse(plannedPieces.text) ?? 0) <= 0) 'quantité à recevoir',
      if (temporary && temporaryInputProductId == null) 'matière première',
      if (temporary && temporarySourceDepotId == null) 'dépôt de départ',
      if (temporary && (int.tryParse(temporaryInputPieces.text) ?? 0) <= 0) 'quantité de matière première envoyée',
      if (temporary && type == MachineType.roulage && (int.tryParse(hopperPieces.text) ?? 0) <= 0) 'tôles par cadous',
    ];
    if (missing.isNotEmpty) {
      message(context, 'Il manque : ${missing.join(', ')}.');
      return;
    }
    if (temporary && int.parse(temporaryInputPieces.text) > widget.available(temporaryInputProductId!, temporarySourceDepotId!)) {
      message(context, 'La quantité de matière première dépasse le stock disponible dans ce dépôt.');
      return;
    }
    Navigator.pop(
      context,
      FactoryMachine(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        name: name.text.trim(),
        type: type,
        categoryId: categoryId ?? '',
        outputId: outputId!,
        units: List.generate(temporary ? 1 : int.parse(copies.text),
          (index) => MachineUnit(number: index + 1, image: temporary ? null : unitImages[index])),
        operatorIds: operators.toList(),
        image: temporary ? null : unitImages.first,
        temporary: temporary,
        deadline: deadline,
        plannedPieces: temporary ? int.parse(plannedPieces.text) : null,
        hopperPieces: temporary && type == MachineType.roulage ? int.parse(hopperPieces.text) : null,
        temporaryInputProductId: temporary ? temporaryInputProductId : null,
        temporarySourceDepotId: temporary ? temporarySourceDepotId : null,
        temporaryInputPieces: temporary ? int.parse(temporaryInputPieces.text) : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FormShell(
      title: 'Ajouter une machine',
      child: Form(
        key: form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.canCreateTemporary)
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('Machine normale')),
                  ButtonSegment(value: true, label: Text('Travail externe temporaire')),
                ],
                selected: {temporary},
                onSelectionChanged: (value) => setState(() => temporary = value.first),
              ),
            const SizedBox(height: 14),
            TextFormField(
              controller: name,
              decoration: const InputDecoration(
                labelText: 'Nom de la machine *',
              ),
              validator: required,
            ),
            const SizedBox(height: 12),
            if (!temporary) ...[
              const Text('Chaque exemplaire a sa propre photo et sa propre carte.', style: TextStyle(color: AppPalette.muted)),
              const SizedBox(height: 12),
              TextFormField(
                controller: copies,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(labelText: 'Nombre d’exemplaires *'),
                validator: positive,
                onChanged: (_) => setState(syncUnitImages),
              ),
              const SizedBox(height: 12),
              ...List.generate(unitImages.length, (index) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: ImageInput(
                  bytes: unitImages[index],
                  label: 'Photo de l’exemplaire n°${index + 1} *',
                  onTap: () => pickUnitImage(index),
                ),
              )),
            ] else ...[
              const Text('À utiliser quand des pièces sont envoyées chez un voisin. Aucun opérateur ni photo n’est requis ; le stock ne sera crédité qu’après validation.', style: TextStyle(color: AppPalette.muted)),
              const SizedBox(height: 12),
              TextFormField(controller: plannedPieces, keyboardType: TextInputType.number, inputFormatters: [FilteringTextInputFormatter.digitsOnly], decoration: const InputDecoration(labelText: 'Quantité attendue au retour *'), validator: positive),
              const SizedBox(height: 12),
              OutlinedButton.icon(onPressed: selectDeadline, icon: const Icon(Icons.event_outlined), label: Text(deadline == null ? 'Choisir la date de fin *' : 'Fin prévue : ${dateText(deadline!)}')),
            ],
            const SizedBox(height: 14),
            SegmentedButton<MachineType>(
              segments: const [
                ButtonSegment(
                  value: MachineType.standard,
                  label: Text('Standard'),
                ),
                ButtonSegment(
                  value: MachineType.roulage,
                  label: Text('Roulage'),
                ),
              ],
              selected: {type},
              onSelectionChanged: (v) => setState(() => type = v.first),
            ),
            if (temporary && type == MachineType.roulage) ...[
              const SizedBox(height: 12),
              TextFormField(controller: hopperPieces, keyboardType: TextInputType.number, inputFormatters: [FilteringTextInputFormatter.digitsOnly], decoration: const InputDecoration(labelText: 'Nombre de tôles par cadous *'), validator: positive),
            ],
            const SizedBox(height: 20),
            Text(
              temporary ? 'Catégorie de la matière première *' : 'Catégorie traitée *',
              style: const TextStyle(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 8),
            CategoryPicker(
              categories: widget.categories,
              selected: categoryId,
              onTap: (category) => setState(() {
                categoryId = category.id;
                temporaryInputProductId = null;
                temporarySourceDepotId = null;
              }),
            ),
            const SizedBox(height: 6),
            Text(
              temporary
                  ? 'Choisissez ensuite la matière envoyée : elle sera déduite du stock à la validation.'
                  : 'Le travailleur choisira le produit de cette catégorie au démarrage.',
              style: const TextStyle(fontSize: 12, color: Color(0xFF725280)),
            ),
            if (temporary && categoryId != null) ...[
              const SizedBox(height: 16),
              const Text('Matière première envoyée *', style: TextStyle(fontWeight: FontWeight.w900)),
              const SizedBox(height: 8),
              if (temporaryMaterials.isEmpty)
                const Text('Cette catégorie ne contient aucune matière première utilisable.', style: TextStyle(color: Color(0xFFB45309), fontWeight: FontWeight.w700))
              else
                ProductPicker(
                  products: temporaryMaterials,
                  selected: temporaryInputProductId == null ? <String>{} : {temporaryInputProductId!},
                  onTap: (product) => setState(() {
                    temporaryInputProductId = product.id;
                    temporarySourceDepotId = null;
                  }),
                ),
              if (temporaryInputProductId != null) ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: temporarySourceDepotId,
                  decoration: const InputDecoration(labelText: 'Dépôt de départ *'),
                  items: widget.depots.map((depot) => DropdownMenuItem(
                    value: depot.id,
                    child: Text('${depot.name} (${widget.available(temporaryInputProductId!, depot.id)} pièces)'),
                  )).toList(),
                  onChanged: (value) => setState(() => temporarySourceDepotId = value),
                ),
              ],
              if (temporaryInputProductId != null && temporarySourceDepotId != null) ...[
                const SizedBox(height: 12),
                TextFormField(
                  controller: temporaryInputPieces,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: InputDecoration(labelText: 'Quantité envoyée *', helperText: 'Disponible : ${widget.available(temporaryInputProductId!, temporarySourceDepotId!)} pièce(s)'),
                  validator: positive,
                ),
              ],
            ],
            const SizedBox(height: 18),
            const Text(
              'Produit fabriqué par la machine *',
              style: TextStyle(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 8),
            if (manufacturedProducts.isEmpty)
              const Text(
                'Créez d’abord un produit marqué « fabriqué en usine », puis sélectionnez-le ici comme résultat de cette machine.',
                style: TextStyle(
                  color: Color(0xFFB45309),
                  fontWeight: FontWeight.w700,
                ),
              )
            else
              ProductPicker(
                products: manufacturedProducts,
                selected: outputId == null ? <String>{} : {outputId!},
                onTap: (product) => setState(() => outputId = product.id),
              ),
            const SizedBox(height: 18),
            if (!temporary) Row(
              children: [
                const Expanded(
                  child: Text(
                    'Opérateur responsable *',
                    style: TextStyle(fontWeight: FontWeight.w900),
                  ),
                ),
                if (widget.canManageUsers)
                  TextButton.icon(
                    onPressed: addUser,
                    icon: const Icon(Icons.person_add_alt_1),
                    label: const Text('Ajouter'),
                  ),
              ],
            ),
            if (!temporary) ...widget.users
                .where((u) => u.isOperator)
                .map(
                  (u) => CheckboxListTile(
                    value: operators.contains(u.id),
                    contentPadding: EdgeInsets.zero,
                    title: Text(u.fullName),
                    subtitle: Text('@${u.username}'),
                    onChanged: (v) => setState(
                      () => v == true
                          ? operators.add(u.id)
                          : operators.remove(u.id),
                    ),
                  ),
                ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: save,
                child: Text(temporary ? 'Envoyer à la validation' : 'Enregistrer la machine'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ProductPicker extends StatelessWidget {
  const ProductPicker({
    super.key,
    required this.products,
    required this.selected,
    required this.onTap,
  });
  final List<Product> products;
  final Set<String> selected;
  final ValueChanged<Product> onTap;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 10,
    runSpacing: 10,
    children: products.map((product) {
      final isSelected = selected.contains(product.id);
      return SizedBox(
        width: 145,
        child: InkWell(
          onTap: () => onTap(product),
          borderRadius: BorderRadius.circular(18),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: isSelected
                  ? const Color(0xFFE9D5FF)
                  : Colors.white.withValues(alpha: .52),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: isSelected ? const Color(0xFF9333EA) : Colors.white,
                width: isSelected ? 2 : 1,
              ),
            ),
            child: AnimatedScale(
              duration: const Duration(milliseconds: 220),
              scale: isSelected ? 1.03 : 1,
              child: Column(
                children: [
                ProductImage(product: product, height: 68),
                const SizedBox(height: 5),
                Text(
                  product.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                ],
              ),
            ),
          ),
        ),
      );
    }).toList(),
  );
}

class CategoryPicker extends StatelessWidget {
  const CategoryPicker({
    super.key,
    required this.categories,
    required this.selected,
    required this.onTap,
  });
  final List<ProductCategory> categories;
  final String? selected;
  final ValueChanged<ProductCategory> onTap;
  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 10,
    runSpacing: 10,
    children: categories.map((category) {
      final isSelected = category.id == selected;
      return SizedBox(
        width: 145,
        child: InkWell(
          onTap: () => onTap(category),
          borderRadius: BorderRadius.circular(18),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: isSelected
                  ? const Color(0xFFE9D5FF)
                  : Colors.white.withValues(alpha: .52),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: isSelected ? const Color(0xFF9333EA) : Colors.white,
                width: isSelected ? 2 : 1,
              ),
            ),
            child: Column(children: [
              CategoryImage(category: category, size: 68),
              const SizedBox(height: 5),
              Text(
                category.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ]),
          ),
        ),
      );
    }).toList(),
  );
}

class StartOperation extends StatefulWidget {
  const StartOperation({
    super.key,
    required this.machine,
    required this.available,
    required this.user,
    required this.category,
    required this.products,
    required this.depots,
    required this.unitNumber,
  });
  final FactoryMachine machine;
  final int Function(String, String) available;
  final AppUser user;
  final ProductCategory? category;
  final List<Product> products;
  final List<Depot> depots;
  final int unitNumber;
  @override
  State<StartOperation> createState() => _StartOperationState();
}

class _StartOperationState extends State<StartOperation> {
  final pieces = TextEditingController();
  final hopper = TextEditingController();
  String? productId;
  String? depotId;
  List<Product> get categoryProducts => widget.products
      .where(
        (product) =>
            product.canBeUsedInMachine &&
            (widget.category?.productIds.contains(product.id) ?? false),
      )
      .toList();

  Product? get outputProduct {
    for (final product in widget.products) {
      if (product.id == widget.machine.outputId) return product;
    }
    return null;
  }

  void start() {
    final n = int.tryParse(pieces.text);
    final h = int.tryParse(hopper.text);
    if (n == null ||
        n <= 0 ||
        productId == null ||
        depotId == null ||
        n > widget.available(productId!, depotId!) ||
        (widget.machine.type == MachineType.roulage && (h == null || h <= 0))) {
      message(
        context,
        'Vérifiez la quantité disponible et la capacité du chariot.',
      );
      return;
    }
    Navigator.pop(
      context,
      Operation(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        machineId: widget.machine.id,
        operatorId: widget.user.id,
        pieces: n,
        productId: productId!,
        sourceDepotId: depotId!,
        machineUnitNumber: widget.unitNumber,
        hopperPieces: widget.machine.type == MachineType.roulage ? h : null,
        startedAt: DateTime.now(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => FormShell(
    title: 'Démarrer une opération',
    subtitle: widget.machine.name,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Choisissez le produit de la catégorie puis la quantité à travailler.',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 14),
        if (widget.category != null) ...[
          Glass(
            padding: const EdgeInsets.all(10),
            child: Row(children: [
              CategoryImage(category: widget.category!, size: 50),
              const SizedBox(width: 10),
              Expanded(child: Text('Catégorie : ${widget.category!.name}', style: const TextStyle(fontWeight: FontWeight.w900))),
            ]),
          ),
          const SizedBox(height: 14),
        ],
        Glass(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              const Icon(
                Icons.inventory_2_outlined,
                color: Color(0xFF15803D),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  'Produit qui sera fabriqué : ${outputProduct?.name ?? 'Non défini'}',
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        if (categoryProducts.isEmpty)
          const Text(
            'Cette catégorie ne contient encore aucun produit.',
            style: TextStyle(color: Color(0xFFB45309), fontWeight: FontWeight.w800),
          )
        else ...[
          const Text('Produit à travailler *', style: TextStyle(fontWeight: FontWeight.w900)),
          const SizedBox(height: 8),
          ProductPicker(
            products: categoryProducts,
            selected: productId == null ? <String>{} : {productId!},
            onTap: (product) => setState(() {
              productId = product.id;
              depotId = null;
            }),
          ),
          if (productId != null) ...[
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: depotId,
              decoration: const InputDecoration(labelText: 'Dépôt où se trouve le produit *'),
              items: widget.depots.map((depot) => DropdownMenuItem(
                value: depot.id,
                child: Text('${depot.name} (${widget.available(productId!, depot.id)} pièces)'),
              )).toList(),
              onChanged: (value) => setState(() => depotId = value),
            ),
          ],
          if (productId != null && depotId != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Stock disponible dans ce dépôt : ${widget.available(productId!, depotId!)} pièce(s)',
                style: const TextStyle(color: Color(0xFF725280)),
              ),
            ),
        ],
        const SizedBox(height: 12),
        Glass(
          padding: const EdgeInsets.all(10),
          child: Row(children: [const Icon(Icons.precision_manufacturing_outlined), const SizedBox(width: 8), Text('Exemplaire n°${widget.unitNumber}', style: const TextStyle(fontWeight: FontWeight.w800))]),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: pieces,
          onChanged: (_) => setState(() {}),
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(
            labelText: 'Nombre de pièces à travailler *',
          ),
        ),
        if (widget.machine.type == MachineType.roulage) ...[
          const SizedBox(height: 12),
          TextField(
            controller: hopper,
            onChanged: (_) => setState(() {}),
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              labelText: 'Nombre de tôles dans le cadous *',
            ),
          ),
          if ((int.tryParse(hopper.text) ?? 0) > 0)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Longueur calculée du cadous : ${formatNumber((int.parse(hopper.text)) * Operation.hopperSheetLengthMeters)} m '
                '(${hopper.text} tôle(s) × ${formatNumber(Operation.hopperSheetLengthMeters)} m)',
                style: const TextStyle(
                  color: Color(0xFF725280),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          if ((int.tryParse(hopper.text) ?? 0) > 0 && (int.tryParse(pieces.text) ?? 0) > 0)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Avec ${pieces.text} tôle(s) et ${hopper.text} tôle(s) par cadous : maximum ${int.parse(pieces.text) ~/ int.parse(hopper.text)} cadous, avec ${int.parse(pieces.text) % int.parse(hopper.text)} tôle(s) restante(s).',
                style: const TextStyle(color: Color(0xFF15803D), fontWeight: FontWeight.w700),
              ),
            ),
        ],
        const SizedBox(height: 14),
        const Text(
          'Le stock sera réservé immédiatement et l’opération sera affichée comme « en cours ».',
          style: TextStyle(fontSize: 12, color: Color(0xFF725280)),
        ),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: start,
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('Démarrer le travail'),
          ),
        ),
      ],
    ),
  );
}

class Completion {
  const Completion({
    required this.outputPieces,
    required this.image,
    required this.finishedAt,
    required this.outputDepotId,
    required this.scrapPieces,
    required this.remainderPieces,
    this.remainderImage,
    this.remainderDepotId,
    this.scrapImage,
    this.scrapDepotId,
  });
  final int outputPieces;
  final Uint8List image;
  final DateTime finishedAt;
  final Uint8List? remainderImage;
  final String outputDepotId;
  final String? remainderDepotId;
  final int scrapPieces;
  final int remainderPieces;
  final Uint8List? scrapImage;
  final String? scrapDepotId;
}

class FinishOperation extends StatefulWidget {
  const FinishOperation({
    super.key,
    required this.operation,
    required this.machine,
    required this.output,
    required this.depots,
  });
  final Operation operation;
  final FactoryMachine machine;
  final Product output;
  final List<Depot> depots;
  @override
  State<FinishOperation> createState() => _FinishOperationState();
}

class _FinishOperationState extends State<FinishOperation> {
  final pieces = TextEditingController();
  final remainderPieces = TextEditingController(text: '0');
  final scrapPieces = TextEditingController(text: '0');
  Uint8List? image;
  Uint8List? remainderImage;
  Uint8List? scrapImage;
  String? outputDepotId;
  String? remainderDepotId;
  String? scrapDepotId;
  int step = 0;

  Future<void> pick(ValueChanged<Uint8List> onPicked) async {
    final file = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 82,
      maxWidth: 1600,
    );
    if (file != null) {
      final bytes = await file.readAsBytes();
      if (mounted) setState(() => onPicked(bytes));
    }
  }

  void finish() {
    final n = int.tryParse(pieces.text);
    final remainder = int.tryParse(remainderPieces.text) ?? -1;
    final scrap = int.tryParse(scrapPieces.text) ?? 0;
    final isRoulage = widget.machine.type == MachineType.roulage;
    final hopperSize = widget.operation.hopperPieces;
    final used = n == null ? -1 : isRoulage ? n * (hopperSize ?? 0) : n;
    final balanced = n != null && n >= 0 && used >= 0 &&
        used + remainder + scrap == widget.operation.pieces;
    final remainderComplete = remainder == 0 ||
        (remainderDepotId != null && remainderImage != null);
    final scrapComplete = scrap == 0 || (scrapDepotId != null && scrapImage != null);
    if (!balanced || remainder < 0 || scrap < 0 || image == null ||
        outputDepotId == null || !remainderComplete || !scrapComplete) {
      setState(() => step = 0);
      message(
        context,
        'Les calculs ou les informations de dépôt sont incomplets. Revenez aux pages : fabriqué + restant + déchets doit égaler ${widget.operation.pieces}.',
      );
      return;
    }
    Navigator.pop(
      context,
      Completion(
        outputPieces: n,
        image: image!,
        finishedAt: DateTime.now(),
        outputDepotId: outputDepotId!,
        scrapPieces: scrap,
        remainderPieces: remainder,
        remainderImage: remainderImage,
        remainderDepotId: remainderDepotId,
        scrapImage: scrapImage,
        scrapDepotId: scrapDepotId,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final made = int.tryParse(pieces.text) ?? 0;
    final remaining = int.tryParse(remainderPieces.text) ?? 0;
    final waste = int.tryParse(scrapPieces.text) ?? 0;
    final used = widget.machine.type == MachineType.roulage
        ? made * (widget.operation.hopperPieces ?? 0)
        : made;
    final difference = widget.operation.pieces - used - remaining - waste;
    final body = switch (step) {
      0 => Column(children: [
          TextField(controller: pieces, onChanged: (_) => setState(() {}), keyboardType: TextInputType.number, inputFormatters: [FilteringTextInputFormatter.digitsOnly], decoration: InputDecoration(labelText: widget.machine.type == MachineType.roulage ? 'Nombre de cadous fabriqués *' : 'Quantité de ${widget.output.name} fabriquée *')),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(initialValue: outputDepotId, decoration: InputDecoration(labelText: 'Dépôt du produit fini ${widget.output.name} *'), items: widget.depots.map((depot) => DropdownMenuItem(value: depot.id, child: Text(depot.name))).toList(), onChanged: (value) => setState(() => outputDepotId = value)),
          const SizedBox(height: 14),
          ImageInput(bytes: image, label: 'Photo du produit fabriqué *', onTap: () => pick((value) => image = value)),
        ]),
      1 => Column(children: [
          const Text('Déclarez uniquement les pièces non travaillées. Elles retourneront au stock de matière première.', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          TextField(controller: remainderPieces, onChanged: (_) => setState(() {}), keyboardType: TextInputType.number, inputFormatters: [FilteringTextInputFormatter.digitsOnly], decoration: const InputDecoration(labelText: 'Pièces restantes non travaillées')),
          if (remaining > 0) ...[
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(initialValue: remainderDepotId, decoration: const InputDecoration(labelText: 'Dépôt qui reçoit les pièces restantes *'), items: widget.depots.map((depot) => DropdownMenuItem(value: depot.id, child: Text(depot.name))).toList(), onChanged: (value) => setState(() => remainderDepotId = value)),
            const SizedBox(height: 14),
            ImageInput(bytes: remainderImage, label: 'Photo des pièces dans le dépôt *', onTap: () => pick((value) => remainderImage = value)),
          ],
        ]),
      _ => Column(children: [
          const Text('Les déchets sont stockés comme un produit « Déchets » séparé.', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          TextField(controller: scrapPieces, onChanged: (_) => setState(() {}), keyboardType: TextInputType.number, inputFormatters: [FilteringTextInputFormatter.digitsOnly], decoration: const InputDecoration(labelText: 'Quantité de déchets')),
          if (waste > 0) ...[
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(initialValue: scrapDepotId, decoration: const InputDecoration(labelText: 'Dépôt qui reçoit les déchets *'), items: widget.depots.map((depot) => DropdownMenuItem(value: depot.id, child: Text(depot.name))).toList(), onChanged: (value) => setState(() => scrapDepotId = value)),
            const SizedBox(height: 14),
            ImageInput(bytes: scrapImage, label: 'Photo des déchets dans le dépôt *', onTap: () => pick((value) => scrapImage = value)),
          ],
          const SizedBox(height: 14),
          Glass(padding: const EdgeInsets.all(12), child: Row(children: [Icon(difference == 0 ? Icons.task_alt_rounded : Icons.calculate_outlined, color: difference == 0 ? const Color(0xFF15803D) : const Color(0xFFB45309)), const SizedBox(width: 8), Expanded(child: Text('Fabriqué : $used + restant : $remaining + déchets : $waste = ${used + remaining + waste} sur ${widget.operation.pieces}${difference == 0 ? ' · équilibre exact' : ' · écart : $difference'}', style: const TextStyle(fontWeight: FontWeight.w800)))])),
        ]),
    };
    return FormShell(title: 'Terminer l’opération · ${step + 1}/3', subtitle: widget.machine.name, child: Column(children: [
      Text(widget.machine.type == MachineType.roulage ? 'Matière initiale : ${widget.operation.pieces} tôles · ${widget.operation.hopperPieces} tôles par cadous' : 'Quantité initiale : ${widget.operation.pieces} pièce(s)', style: const TextStyle(fontWeight: FontWeight.w800)),
      const SizedBox(height: 16), body, const SizedBox(height: 20),
      Row(children: [if (step > 0) Expanded(child: OutlinedButton(onPressed: () => setState(() => step--), child: const Text('Précédent'))), if (step > 0) const SizedBox(width: 10), Expanded(child: FilledButton.icon(onPressed: step == 2 ? finish : () => setState(() => step++), icon: Icon(step == 2 ? Icons.task_alt_rounded : Icons.arrow_forward_rounded), label: Text(step == 2 ? 'Vérifier et terminer' : 'Continuer')))]),
    ]));
  }
}

class Receipt extends StatelessWidget {
  const Receipt({
    super.key,
    required this.operation,
    required this.machine,
    required this.output,
    required this.operator,
  });
  final Operation operation;
  final FactoryMachine machine;
  final Product output;
  final AppUser operator;
  @override
  Widget build(BuildContext context) => AlertDialog(
    backgroundColor: const Color(0xFFFEFBFF),
    title: const Row(
      children: [
        Icon(Icons.receipt_long_rounded, color: Color(0xFF7E22CE)),
        SizedBox(width: 8),
        Text('Bon de production'),
      ],
    ),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            machine.name,
            style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18),
          ),
          const Divider(),
          Text('Opérateur : ${operator.fullName}'),
          Text('Début : ${dateText(operation.startedAt)}'),
          Text('Fin : ${dateText(operation.finishedAt!)}'),
          Text('Matière réservée : ${operation.pieces} pièce(s)'),
          if (operation.hopperPieces != null)
            Text(
              'Cadous : ${operation.hopperPieces} tôle(s) · '
              '${formatNumber(operation.hopperLengthMeters!)} m',
            ),
          Text('Produit fini : ${output.name}'),
          Text(
            operation.hopperPieces == null
                ? 'Quantité fabriquée : ${operation.outputPieces} pièce(s)'
                : 'Cadous fabriqués : ${operation.outputPieces} · ${operation.scrapPieces} tôle(s) restante(s)',
            style: const TextStyle(fontWeight: FontWeight.w900),
          ),
          if (operation.needsReview) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFFFFEDD5),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '⚠ ${operation.pieces - (operation.outputPieces ?? 0)} pièce(s) restante(s) photographiée(s) et envoyée(s) au contrôle.',
                style: const TextStyle(
                  color: Color(0xFF92400E),
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Image.memory(
              operation.finalImage!,
              height: 150,
              width: 270,
              fit: BoxFit.cover,
            ),
          ),
          if (operation.remainderImage != null) ...[
            const SizedBox(height: 10),
            const Text('Photo des pièces restantes', style: TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 5),
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Image.memory(operation.remainderImage!, height: 120, width: 270, fit: BoxFit.cover),
            ),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Fermer'),
      ),
    ],
  );
}

class UserDetailsPage extends StatefulWidget {
  const UserDetailsPage({
    super.key,
    required this.user,
    required this.canManage,
    required this.loadSessions,
  });
  final AppUser user;
  final bool canManage;
  final Future<List<UserSession>> Function(String) loadSessions;
  @override
  State<UserDetailsPage> createState() => _UserDetailsPageState();
}

class _UserDetailsPageState extends State<UserDetailsPage> {
  late Set<UserRole> roles;
  late Set<AppPage> pages;
  late Set<AppPage> writablePages;
  late UserStatus status;
  DateTime? leaveUntil;
  late Future<List<UserSession>> sessions;
  final newPassword = TextEditingController();
  final passwordConfirmation = TextEditingController();

  @override
  void initState() {
    super.initState();
    roles = {...widget.user.roles};
    pages = {...widget.user.allowedPages};
    writablePages = {...widget.user.writablePages};
    status = widget.user.status;
    leaveUntil = widget.user.leaveUntil;
    sessions = widget.loadSessions(widget.user.id);
  }

  Future<void> setLeave() async {
    final selected = await showDatePicker(
      context: context,
      initialDate: leaveUntil ?? DateTime.now().add(const Duration(days: 7)),
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 3650)),
    );
    if (selected != null) setState(() { status = UserStatus.onLeave; leaveUntil = selected; });
  }

  @override
  void dispose() {
    newPassword.dispose();
    passwordConfirmation.dispose();
    super.dispose();
  }

  void save() {
    if (roles.isEmpty) {
      message(context, 'Choisissez au moins un rôle pour cet utilisateur.');
      return;
    }
    final requestedPassword = newPassword.text;
    if (requestedPassword.isNotEmpty) {
      final validation = securePasswordValidator(requestedPassword);
      if (validation != null) {
        message(context, validation);
        return;
      }
      if (requestedPassword != passwordConfirmation.text) {
        message(context, 'Les mots de passe ne correspondent pas.');
        return;
      }
    }
    Navigator.pop(context, widget.user.copyWith(
      password: requestedPassword.isEmpty ? null : requestedPassword,
      roles: roles,
      allowedPages: pages,
      writablePages: writablePages,
      status: status,
      leaveUntil: leaveUntil,
      clearLeaveUntil: status != UserStatus.onLeave,
    ));
  }

  Widget accessCheck(AppPage page) => CheckboxListTile(
    dense: true,
    contentPadding: EdgeInsets.zero,
    value: pages.contains(page),
    title: Text(page.label),
    subtitle: Text(writablePages.contains(page) ? 'Accès et ajout/modification' : 'Consultation seulement'),
    onChanged: !widget.canManage ? null : (value) => setState(() {
      if (value ?? false) { pages.add(page); } else { pages.remove(page); writablePages.remove(page); }
    }),
    secondary: IconButton(
      tooltip: 'Autoriser l’ajout et la modification',
      onPressed: !widget.canManage || !pages.contains(page) ? null : () => setState(() {
        if (writablePages.contains(page)) { writablePages.remove(page); } else { writablePages.add(page); }
      }),
      icon: Icon(writablePages.contains(page) ? Icons.edit_rounded : Icons.visibility_outlined),
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Fiche utilisateur')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Glass(child: ListTile(
            leading: CircleAvatar(child: Text(widget.user.fullName.substring(0, 1).toUpperCase())),
            title: Text(widget.user.fullName, style: const TextStyle(fontWeight: FontWeight.w900)),
            subtitle: Text('@${widget.user.username}'),
          )),
          const SizedBox(height: 18),
          const Text('Rôles (cumulables)', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
          ...UserRole.values.map((role) => CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(role.label),
            value: roles.contains(role),
            onChanged: !widget.canManage ? null : (value) => setState(() {
              if (value ?? false) { roles.add(role); } else { roles.remove(role); }
            }),
          )),
          const SizedBox(height: 8),
          const Text('Pages et droit d’ajout', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
          const Text('L’icône œil signifie lecture seule ; le crayon autorise aussi les ajouts et modifications.', style: TextStyle(color: AppPalette.muted, fontSize: 12)),
          const SizedBox(height: 6),
          ...AppPage.values.map(accessCheck),
          const SizedBox(height: 12),
          const Text('Statut du compte', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
          ListTile(
            leading: const Icon(Icons.event_available_outlined),
            title: Text(status == UserStatus.onLeave && leaveUntil != null ? 'En congé jusqu’au ${dateText(leaveUntil!)}' : status.label),
            trailing: widget.canManage ? OutlinedButton(onPressed: setLeave, child: const Text('Donner congé')) : null,
          ),
          if (widget.canManage) Wrap(spacing: 8, children: [
            OutlinedButton.icon(onPressed: () => setState(() { status = UserStatus.active; leaveUntil = null; }), icon: const Icon(Icons.check_circle_outline), label: const Text('Réactiver')),
            OutlinedButton.icon(onPressed: () => setState(() { status = UserStatus.dismissed; leaveUntil = null; }), icon: const Icon(Icons.person_off_outlined), label: const Text('Licencier définitivement')),
          ]),
          if (widget.canManage) ...[
            const SizedBox(height: 20),
            const Text('Réinitialiser le mot de passe', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
            const SizedBox(height: 4),
            const Text('Laissez ces champs vides pour conserver le mot de passe actuel.', style: TextStyle(color: AppPalette.muted, fontSize: 12)),
            const SizedBox(height: 10),
            TextField(
              controller: newPassword,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Nouveau mot de passe'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: passwordConfirmation,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Confirmer le nouveau mot de passe'),
            ),
          ],
          const SizedBox(height: 20),
          const Text('Historique de connexion', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
          FutureBuilder<List<UserSession>>(
            future: sessions,
            builder: (context, snapshot) {
              if (!snapshot.hasData) return const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()));
              if (snapshot.data!.isEmpty) return const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Text('Aucune connexion enregistrée.'));
              return Glass(child: Column(children: snapshot.data!.map((session) => ListTile(
                leading: const Icon(Icons.login_rounded),
                title: Text('Entrée : ${dateText(session.loggedInAt)}'),
                subtitle: Text(session.loggedOutAt == null ? 'Session en cours' : 'Sortie : ${dateText(session.loggedOutAt!)}'),
              )).toList()));
            },
          ),
          if (widget.canManage) ...[
            const SizedBox(height: 24),
            FilledButton.icon(onPressed: save, icon: const Icon(Icons.save_outlined), label: const Text('Enregistrer les droits')),
          ],
        ],
      ),
    ),
  );
}

class UserForm extends StatefulWidget {
  const UserForm({super.key});
  @override
  State<UserForm> createState() => _UserFormState();
}

class _UserFormState extends State<UserForm> {
  final form = GlobalKey<FormState>();
  final full = TextEditingController();
  final user = TextEditingController();
  final password = TextEditingController();
  UserRole role = UserRole.operator;
  void save() {
    if (!(form.currentState?.validate() ?? false)) return;
    Navigator.pop(
      context,
      AppUser(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        username: user.text.trim(),
        password: password.text,
        fullName: full.text.trim(),
        role: role,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => FormShell(
    title: 'Ajouter un utilisateur',
    child: Form(
      key: form,
      child: Column(
        children: [
          TextFormField(
            controller: full,
            decoration: const InputDecoration(labelText: 'Nom réel *'),
            validator: required,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: user,
            decoration: const InputDecoration(labelText: 'Nom d’utilisateur *'),
            validator: usernameValidator,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: password,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Mot de passe *'),
            validator: securePasswordValidator,
          ),
          const SizedBox(height: 18),
          const Align(
            alignment: Alignment.centerLeft,
            child: Text('Rôle *', style: TextStyle(fontWeight: FontWeight.w900)),
          ),
          const SizedBox(height: 8),
          SegmentedButton<UserRole>(
            segments: const [
              ButtonSegment(value: UserRole.operator, label: Text('Opérateur')),
              ButtonSegment(value: UserRole.visitor, label: Text('Visiteur')),
              ButtonSegment(value: UserRole.validation, label: Text('Validation')),
            ],
            selected: {role},
            onSelectionChanged: (value) => setState(() => role = value.first),
          ),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: save,
              child: const Text('Créer l’utilisateur'),
            ),
          ),
        ],
      ),
    ),
  );
}

class ImageInput extends StatelessWidget {
  const ImageInput({
    super.key,
    required this.bytes,
    required this.label,
    required this.onTap,
  });
  final Uint8List? bytes;
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(16),
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      height: bytes == null ? 118 : 174,
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppPalette.soft,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFDCD9F8)),
      ),
      child: bytes == null
          ? Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                  child: const Icon(Icons.add_a_photo_outlined, color: AppPalette.primary),
                ),
                const SizedBox(width: 14),
                Flexible(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
                      const SizedBox(height: 4),
                      const Text('Touchez pour choisir une image', style: TextStyle(color: AppPalette.muted, fontSize: 12)),
                    ],
                  ),
                ),
              ],
            )
          : ClipRRect(
              borderRadius: BorderRadius.circular(15),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.memory(bytes!, fit: BoxFit.cover),
                  Positioned(
                    right: 10,
                    bottom: 10,
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                      child: const Icon(Icons.edit_rounded, size: 18, color: AppPalette.primary),
                    ),
                  ),
                ],
              ),
            ),
    ),
  );
}

class MultiImageInput extends StatelessWidget {
  const MultiImageInput({
    super.key,
    required this.images,
    required this.label,
    required this.onTap,
    required this.onRemove,
  });
  final List<Uint8List> images;
  final String label;
  final VoidCallback onTap;
  final ValueChanged<int> onRemove;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      OutlinedButton.icon(
        onPressed: onTap,
        icon: const Icon(Icons.add_photo_alternate_outlined),
        label: Text(label),
      ),
      if (images.isNotEmpty) ...[
        const SizedBox(height: 8),
        SizedBox(
          height: 92,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: images.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, index) => Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.memory(images[index], width: 92, height: 92, fit: BoxFit.cover),
                ),
                Positioned(
                  top: 2,
                  right: 2,
                  child: Material(
                    color: Colors.white,
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => onRemove(index),
                      child: const Padding(
                        padding: EdgeInsets.all(3),
                        child: Icon(Icons.close_rounded, size: 17, color: Color(0xFFB91C1C)),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    ],
  );
}

class FormShell extends StatelessWidget {
  const FormShell({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
  });
  final String title;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.transparent,
    body: Aura(
      child: SafeArea(
        child: Column(
          children: [
            SizedBox(
              height: 122,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 22, 20),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.arrow_back_rounded),
                      color: AppPalette.primary,
                      style: IconButton.styleFrom(backgroundColor: Colors.white),
                      tooltip: 'Retour',
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title, style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w900, color: Colors.white)),
                          if (subtitle != null) ...[
                            const SizedBox(height: 3),
                            Text(subtitle!, style: const TextStyle(color: Color(0xFFE9E7FF))),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 42),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 620),
                    child: Glass(
                      padding: const EdgeInsets.all(18),
                      child: child,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class Empty extends StatelessWidget {
  const Empty({
    super.key,
    required this.icon,
    required this.title,
    required this.detail,
  });
  final IconData icon;
  final String title;
  final String detail;
  @override
  Widget build(BuildContext context) => Glass(
    padding: const EdgeInsets.all(32),
    child: Center(
      child: Column(
        children: [
          Icon(icon, size: 46, color: const Color(0xFF7E22CE)),
          const SizedBox(height: 10),
          Text(
            title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 5),
          Text(detail, textAlign: TextAlign.center),
        ],
      ),
    ),
  );
}

void message(BuildContext context, String value) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(value)));
String? required(String? value) =>
    value == null || value.trim().isEmpty ? 'Champ obligatoire' : null;

String? usernameValidator(String? value) {
  final name = value?.trim() ?? '';
  if (!RegExp(r'^[a-zA-Z0-9._-]{3,32}$').hasMatch(name)) {
    return '3 à 32 caractères : lettres, chiffres, point, tiret ou _.';
  }
  return null;
}

String? securePasswordValidator(String? value) {
  final password = value ?? '';
  if (password.length < 12) return 'Utilisez au moins 12 caractères.';
  if (password.length > 128) return 'Utilisez au plus 128 caractères.';
  if (!RegExp(r'[a-z]').hasMatch(password) ||
      !RegExp(r'[A-Z]').hasMatch(password) ||
      !RegExp(r'[0-9]').hasMatch(password)) {
    return 'Utilisez au moins une minuscule, une majuscule et un chiffre.';
  }
  return null;
}
String? positive(String? value) =>
    number(value ?? '') <= 0 ? 'Nombre invalide' : null;
double number(String value) => double.tryParse(value.replaceAll(',', '.')) ?? 0;
String formatNumber(num value) {
  final rounded = value.toStringAsFixed(2);
  return rounded
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}

String formatWeight(num kilograms) => kilograms >= 1000
    ? '${formatNumber(kilograms / 1000)} t'
    : '${formatNumber(kilograms)} kg';

String productQuantityLabel(Product product, int quantity) {
  if (product.hoseManagedByMeter) {
    return '$quantity m';
  }
  if (product.isHose) {
    return '$quantity pièce(s) · ${formatNumber(quantity * product.lengthMeters)} m';
  }
  return '$quantity pièce(s)';
}

String productSpecification(Product product) {
  if (product.isHose) {
    return product.hoseManagedByMeter
        ? 'Tuyau au mètre'
        : 'Tuyau à la pièce · ${formatNumber(product.lengthMeters)} m / pièce';
  }
  if (product.isDiameterBased) {
    return 'Ø ${formatNumber(product.displayedDiameter ?? 0)} ${product.displayedDiameterUnit}';
  }
  final length = '${formatNumber(product.lengthInChosenUnit)} ${product.lengthUnit.label}';
  return product.displayedDiameter == null
      ? length
      : '$length · Ø ${formatNumber(product.displayedDiameter!)} ${product.displayedDiameterUnit}';
}

String dateText(DateTime value) =>
    '${value.day.toString().padLeft(2, '0')}/${value.month.toString().padLeft(2, '0')}/${value.year} · ${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
