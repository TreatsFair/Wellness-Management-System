import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../core/utils/responsive.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController    = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscurePassword     = true;
  bool _isLoading           = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _handleSignIn() async {
    final email    = _emailController.text.trim();
    final password = _passwordController.text.trim();

    if (email.isEmpty || password.isEmpty) {
      _showError('Please enter your email and password');
      return;
    }

    setState(() => _isLoading = true);

    try {
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email:    email,
        password: password,
      );
    } on FirebaseAuthException catch (e) {
      String message = 'Sign in failed';
      if (e.code == 'user-not-found')  message = 'No account found for this email';
      if (e.code == 'wrong-password')  message = 'Incorrect password';
      if (e.code == 'invalid-credential') message = 'Invalid email or password';
      if (e.code == 'invalid-email')   message = 'Invalid email address';
      if (e.code == 'user-disabled')   message = 'This account has been disabled';
      if (e.code == 'too-many-requests') message = 'Too many attempts. Try again later';
      _showError(message);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _handleForgotPassword() async {
    final email = _emailController.text.trim();

    if (email.isEmpty) {
      _showError('Enter your email above, then tap Forgot Password');
      return;
    }

    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(email: email);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Reset email sent - check your inbox'),
            backgroundColor: Color(0xFF1B6B72),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } on FirebaseAuthException catch (e) {
      String message = 'Failed to send reset email';
      if (e.code == 'user-not-found') message = 'No account found for this email';
      if (e.code == 'invalid-email') message = 'Invalid email address';
      if (mounted) _showError(message);
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: const Color(0xFFE53935),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isTablet  = Responsive.isTablet(context);
    final hPadding  = Responsive.horizontalPadding(context);

    return Scaffold(
      backgroundColor: const Color(0xFFF8F7F4),
      body: SafeArea(
        child: Center(                         // centers content on tablet
          child: SingleChildScrollView(
            padding: EdgeInsets.symmetric(horizontal: hPadding),
            child: ConstrainedBox(
              // caps form width on tablet so it doesn't stretch too wide
              constraints: const BoxConstraints(maxWidth: 500),
              child: Column(
                children: [
                  SizedBox(height: isTablet ? 80 : 60),

                  // ── Logo ───────────────────────────────────────
                  Container(
                    width:  isTablet ? 110 : 90,
                    height: isTablet ? 110 : 90,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Color(0xFF1B6B72),
                    ),
                    child: ClipOval(
                      child: Image.asset(
                        'assets/images/logo/treats_logo.png',
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => const Icon(
                          Icons.spa_outlined,
                          color: Colors.white,
                          size: 40,
                        ),
                      ),
                    ),
                  ),

                  SizedBox(height: isTablet ? 24 : 20),

                  // ── App name ───────────────────────────────────
                  Text(
                    'Treats',
                    style: TextStyle(
                      fontSize:   isTablet ? 30 : 26,
                      fontWeight: FontWeight.bold,
                      color:      const Color(0xFF1A1A2E),
                    ),
                  ),

                  const SizedBox(height: 6),

                  const Text(
                    'Login Portal',
                    style: TextStyle(
                      fontSize: 14,
                      color:    Color(0xFF9E9E9E),
                    ),
                  ),

                  SizedBox(height: isTablet ? 48 : 40),

                  // ── Form card ──────────────────────────────────
                  Container(
                    width:   double.infinity,
                    padding: EdgeInsets.all(isTablet ? 32 : 24),
                    decoration: BoxDecoration(
                      color:        Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color:      Colors.black.withValues(alpha: 0.07),
                          blurRadius: 20,
                          offset:     const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [

                        // Email
                        _buildLabel('Email'),
                        const SizedBox(height: 8),
                        _buildTextField(
                          controller:  _emailController,
                          hint:        'staff@treats.com',
                          keyType:     TextInputType.emailAddress,
                          isTablet:    isTablet,
                        ),

                        const SizedBox(height: 20),

                        // Password
                        _buildLabel('Password'),
                        const SizedBox(height: 8),
                        _buildPasswordField(isTablet),

                        SizedBox(height: isTablet ? 32 : 28),

                        // Sign In button
                        SizedBox(
                          width:  double.infinity,
                          height: isTablet ? 56 : 52,
                          child: ElevatedButton(
                            onPressed: _isLoading ? null : _handleSignIn,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF1B6B72),
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                              elevation: 0,
                            ),
                            child: _isLoading
                                ? const SizedBox(
                                    width: 20, height: 20,
                                    child: CircularProgressIndicator(
                                      color:       Colors.white,
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Text(
                                    'Sign In',
                                    style: TextStyle(
                                      fontSize:   isTablet ? 17 : 16,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                          ),
                        ),

                        const SizedBox(height: 16),

                        // Forgot password
                        Center(
                          child: GestureDetector(
                            onTap: _handleForgotPassword,
                            child: const Text(
                              'Forgot Password?',
                              style: TextStyle(
                                fontSize:   14,
                                color:      Color(0xFF1B6B72),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 32),

                  const Text(
                    'v1.0.0',
                    style: TextStyle(
                      fontSize: 12,
                      color:    Color(0xFFBDBDBD),
                    ),
                  ),

                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── Reusable helpers ──────────────────────────────────────────────

  Widget _buildLabel(String text) {
    return Text(
      text,
      style: const TextStyle(
        fontSize:   14,
        fontWeight: FontWeight.w600,
        color:      Color(0xFF1A1A2E),
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String hint,
    required TextInputType keyType,
    required bool isTablet,
  }) {
    return TextField(
      controller:   controller,
      keyboardType: keyType,
      style: TextStyle(
        fontSize: isTablet ? 15 : 14,
        color:    const Color(0xFF1A1A2E),
      ),
      decoration: InputDecoration(
        hintText:  hint,
        hintStyle: const TextStyle(color: Color(0xFFBDBDBD), fontSize: 14),
        filled:    true,
        fillColor: const Color(0xFFF5F5F5),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide:   BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(
            color: Color(0xFF1B6B72),
            width: 1.5,
          ),
        ),
        contentPadding: EdgeInsets.symmetric(
          horizontal: 16,
          vertical:   isTablet ? 16 : 14,
        ),
      ),
    );
  }

  Widget _buildPasswordField(bool isTablet) {
    return TextField(
      controller:  _passwordController,
      obscureText: _obscurePassword,
      style: TextStyle(
        fontSize: isTablet ? 15 : 14,
        color:    const Color(0xFF1A1A2E),
      ),
      decoration: InputDecoration(
        hintText:  '••••••••',
        hintStyle: const TextStyle(color: Color(0xFFBDBDBD), fontSize: 14),
        filled:    true,
        fillColor: const Color(0xFFF5F5F5),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide:   BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(
            color: Color(0xFF1B6B72),
            width: 1.5,
          ),
        ),
        contentPadding: EdgeInsets.symmetric(
          horizontal: 16,
          vertical:   isTablet ? 16 : 14,
        ),
        suffixIcon: GestureDetector(
          onTap: () => setState(() => _obscurePassword = !_obscurePassword),
          child: Icon(
            _obscurePassword
                ? Icons.visibility_outlined
                : Icons.visibility_off_outlined,
            color: const Color(0xFF9E9E9E),
            size:  20,
          ),
        ),
      ),
    );
  }
}
