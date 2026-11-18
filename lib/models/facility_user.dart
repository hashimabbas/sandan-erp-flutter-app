/// The 4 Facility-app roles, per SPEC-003 §2 — mirrors the role slugs
/// `FacilityPermissionSeeder` assigns on the backend.
enum FacilityRole {
  facilityManager('facility-manager'),
  supervisor('supervisor'),
  technician('technician'),
  worker('worker');

  const FacilityRole(this.slug);

  final String slug;

  static FacilityRole fromSlug(String slug) {
    return FacilityRole.values.firstWhere(
      (role) => role.slug == slug,
      orElse: () => throw ArgumentError('Unknown facility role: $slug'),
    );
  }
}

class FacilityUser {
  const FacilityUser({required this.id, required this.name, required this.role});

  final int id;
  final String name;
  final FacilityRole role;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'role': role.slug,
      };

  factory FacilityUser.fromJson(Map<String, dynamic> json) => FacilityUser(
        id: json['id'] as int,
        name: json['name'] as String,
        role: FacilityRole.fromSlug(json['role'] as String),
      );
}
