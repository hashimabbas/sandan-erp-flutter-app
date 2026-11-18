import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../widgets/animated_gradient_background.dart';
import '../widgets/brand_logo.dart';
import '../widgets/glass_card.dart';
import '../widgets/premium_button.dart';

/// SPEC-024 Phase 4, Step 5 — this screen used to **lie**, and that is why it
/// was rewritten rather than left alone.
///
/// 🔴 **What it did before.** It took an email address, waited 1.2 seconds on
/// a `Future.delayed`, and then showed a success state telling the user a
/// reset link had been sent. Nothing was ever sent. The Spec called the stub
/// *"a button that silently does nothing"* — it was worse than that: a dead
/// button teaches a man to ask for help, and this one taught him to **wait for
/// a message that cannot arrive**.
///
/// 🔴 **Measured 2026-10-28, which is why no form replaces it.** Fortify's
/// reset feature *is* enabled, but its routes are **web** routes — session,
/// CSRF, an Inertia page and an emailed link to a browser URL — and
/// `MAIL_MAILER=log`, so **no reset message leaves this system at all**.
/// `/api/facility/*` has no password-reset route to call. Wiring the real
/// endpoint today would produce exactly the outcome the fake did.
///
/// ⚠️ **The sentence below is a PLACEHOLDER awaiting Sandan's answer** to:
/// *when a technician forgets his password, who resets it?* The two likely
/// answers cost different things — the facility manager needs an ERP screen
/// that does not exist, and an IT contact needs an address the app can show.
/// Until then this says the thing that is true today: a `facility-manager` can
/// reach the ERP and a technician cannot.
///
/// 🎯 **The test for this screen is not "does it work" but "does it say
/// something true".** It asserts there is **no** email field and **no**
/// success state.
class ForgotPasswordScreen extends StatelessWidget {
  const ForgotPasswordScreen({super.key});

  /// ⚠️ Kept as a named constant so the day Sandan answers, one string
  /// changes — and so a search for it finds this note.
  static const placeholderGuidance =
      'Ask your facility manager to reset your password. '
      'The app cannot reset it for you yet.';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AnimatedGradientBackground(
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.arrow_back_rounded, color: AppColors.textPrimary),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 22),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox(height: 12),
                      const BrandLogo(size: 64),
                      const SizedBox(height: 22),
                      GlassCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Forgotten password',
                              style: TextStyle(
                                color: AppColors.textPrimary,
                                fontSize: 19,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 10),
                            const Text(
                              placeholderGuidance,
                              style: TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 13.5,
                                height: 1.5,
                              ),
                            ),
                            const SizedBox(height: 16),
                            // ✅ And the thing he CAN do, said in the same
                            // breath: once he is signed in, he may change it
                            // himself from Account.
                            const Text(
                              'If you are already signed in, you can change your password '
                              'yourself under Account.',
                              style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                            ),
                            const SizedBox(height: 20),
                            PremiumButton(
                              label: 'Back to sign in',
                              onPressed: () => Navigator.of(context).pop(),
                            ),
                          ],
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
