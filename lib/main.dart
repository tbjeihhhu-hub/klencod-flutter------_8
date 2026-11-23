import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:http/http.dart' as http;

const Color purple = Color(0xFF6C3CE8);

const String workerUrl =
    'https://souq-alhamadi-image-auth.zzailaz17.workers.dev';

const String imageKitUploadUrl =
    'https://upload.imagekit.io/api/v1/files/upload';

final db = FirebaseFirestore.instance;

const List<String> iraqProvinces = [
  'بغداد',
  'البصرة',
  'نينوى',
  'أربيل',
  'السليمانية',
  'دهوك',
  'كركوك',
  'ديالى',
  'الأنبار',
  'صلاح الدين',
  'بابل',
  'كربلاء',
  'النجف',
  'القادسية',
  'المثنى',
  'ذي قار',
  'ميسان',
  'واسط',
];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  runApp(const SouqAlHamadi());
}

// الحصول على توقيع ImageKit من Cloudflare ثم رفع الصورة
Future<String> uploadImageToImageKit(File file, User user) async {
  final firebaseToken = await user.getIdToken();

  if (firebaseToken == null || firebaseToken.isEmpty) {
    throw Exception('تعذر التحقق من حسابك، سجل الدخول مرة ثانية');
  }

  final authResponse = await http.post(
    Uri.parse(workerUrl),
    headers: {
      'Authorization': 'Bearer $firebaseToken',
      'Content-Type': 'application/json',
    },
  ).timeout(const Duration(seconds: 30));

  final authData = jsonDecode(authResponse.body);

  if (authResponse.statusCode != 200) {
    final error = authData is Map
        ? authData['error']?.toString() ?? 'فشل الحصول على توقيع الصور'
        : 'فشل الحصول على توقيع الصور';
    throw Exception(error);
  }

  if (authData is! Map ||
      authData['token'] == null ||
      authData['signature'] == null ||
      authData['expire'] == null ||
      authData['publicKey'] == null) {
    throw Exception('بيانات توقيع الصور غير مكتملة');
  }

  final request = http.MultipartRequest(
    'POST',
    Uri.parse(imageKitUploadUrl),
  );

  request.fields['fileName'] =
      'souq_${DateTime.now().millisecondsSinceEpoch}.jpg';
  request.fields['token'] = authData['token'].toString();
  request.fields['signature'] = authData['signature'].toString();
  request.fields['expire'] = authData['expire'].toString();
  request.fields['publicKey'] = authData['publicKey'].toString();

  request.files.add(
    await http.MultipartFile.fromPath('file', file.path),
  );

  final streamedResponse = await request.send().timeout(
    const Duration(minutes: 2),
  );
  final response = await http.Response.fromStream(streamedResponse);
  final result = jsonDecode(response.body);

  if (response.statusCode != 200) {
    final error = result is Map
        ? result['message']?.toString() ??
            result['help']?.toString() ??
            'فشل رفع الصورة'
        : 'فشل رفع الصورة';
    throw Exception(error);
  }

  if (result is! Map || result['url'] == null) {
    throw Exception('ImageKit لم يرجع رابط الصورة');
  }

  return result['url'].toString();
}

class SouqAlHamadi extends StatelessWidget {
  const SouqAlHamadi({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'سوق ال حمادي',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: purple),
        scaffoldBackgroundColor: const Color(0xFFF7F7FB),
      ),
      home: const AuthGate(),
    );
  }
}

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.hasData) {
          return HomePage(user: snapshot.data!);
        }
        return const AuthPage();
      },
    );
  }
}

// تسجيل الدخول وإنشاء الحساب
class AuthPage extends StatefulWidget {
  const AuthPage({super.key});

  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  final formKey = GlobalKey<FormState>();
  final nameController = TextEditingController();
  final emailController = TextEditingController();
  final passwordController = TextEditingController();

  bool isLogin = true;
  bool loading = false;
  bool hidePassword = true;
  String selectedProvince = 'القادسية';

  @override
  void dispose() {
    nameController.dispose();
    emailController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (!formKey.currentState!.validate()) return;
    setState(() => loading = true);

    try {
      final email = emailController.text.trim();
      final password = passwordController.text.trim();

      if (isLogin) {
        await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: email,
          password: password,
        );
      } else {
        final credential =
            await FirebaseAuth.instance.createUserWithEmailAndPassword(
          email: email,
          password: password,
        );

        final name = nameController.text.trim();
        await credential.user!.updateDisplayName(name);

        await db.collection('users').doc(credential.user!.uid).set({
          'uid': credential.user!.uid,
          'name': name,
          'email': email,
          'province': selectedProvince,
          'محافظة': selectedProvince,
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }
    } on FirebaseAuthException catch (e) {
      String message = 'حدث خطأ، حاول مرة ثانية';
      if (e.code == 'email-already-in-use') {
        message = 'هذا الإيميل مستخدم من قبل';
      } else if (e.code == 'invalid-email') {
        message = 'الإيميل غير صحيح';
      } else if (e.code == 'weak-password') {
        message = 'كلمة المرور ضعيفة';
      } else if (e.code == 'user-not-found' ||
          e.code == 'wrong-password' ||
          e.code == 'invalid-credential') {
        message = 'الإيميل أو كلمة المرور غير صحيحة';
      } else if (e.code == 'network-request-failed') {
        message = 'تأكد من اتصال الإنترنت';
      }
      showMessage(message);
    } catch (e) {
      showMessage('تعذر إكمال العملية: $e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> resetPassword() async {
    final email = emailController.text.trim();
    if (!email.contains('@')) {
      showMessage('اكتب إيميلك أولاً');
      return;
    }
    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(email: email);
      showMessage('تم إرسال رابط استعادة كلمة المرور');
    } catch (_) {
      showMessage('تعذر إرسال رابط الاستعادة');
    }
  }

  void showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(22),
              child: Form(
                key: formKey,
                child: Column(
                  children: [
                    Container(
                      width: 95,
                      height: 95,
                      decoration: BoxDecoration(
                        color: purple,
                        borderRadius: BorderRadius.circular(28),
                      ),
                      child: const Icon(
                        Icons.storefront,
                        color: Colors.white,
                        size: 55,
                      ),
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      'سوق ال حمادي',
                      style: TextStyle(
                        fontSize: 29,
                        fontWeight: FontWeight.bold,
                        color: purple,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      isLogin
                          ? 'أهلاً بيك، سجل دخولك للسوق'
                          : 'أنشئ حسابك وابدأ البيع والشراء',
                    ),
                    const SizedBox(height: 30),
                    if (!isLogin) ...[
                      TextFormField(
                        controller: nameController,
                        decoration: inputDecoration(
                          'الاسم الكامل',
                          Icons.person_outline,
                        ),
                        validator: (v) =>
                            v == null || v.trim().length < 3
                                ? 'اكتب اسمك بشكل صحيح'
                                : null,
                      ),
                      const SizedBox(height: 15),
                      DropdownButtonFormField<String>(
                        value: selectedProvince,
                        decoration: inputDecoration(
                          'محافظتك',
                          Icons.location_on_outlined,
                        ),
                        items: iraqProvinces.map((province) {
                          return DropdownMenuItem(
                            value: province,
                            child: Text(province),
                          );
                        }).toList(),
                        onChanged: (value) {
                          if (value != null) {
                            setState(() => selectedProvince = value);
                          }
                        },
                      ),
                      const SizedBox(height: 15),
                    ],
                    TextFormField(
                      controller: emailController,
                      keyboardType: TextInputType.emailAddress,
                      decoration: inputDecoration(
                        'البريد الإلكتروني',
                        Icons.email_outlined,
                      ),
                      validator: (v) =>
                          v == null ||
                                  !RegExp(r'^[^@]+@[^@]+\.[^@]+$')
                                      .hasMatch(v.trim())
                              ? 'اكتب إيميل صحيح'
                              : null,
                    ),
                    const SizedBox(height: 15),
                    TextFormField(
                      controller: passwordController,
                      obscureText: hidePassword,
                      decoration: inputDecoration(
                        'كلمة المرور',
                        Icons.lock_outline,
                      ).copyWith(
                        suffixIcon: IconButton(
                          onPressed: () {
                            setState(() => hidePassword = !hidePassword);
                          },
                          icon: Icon(
                            hidePassword
                                ? Icons.visibility
                                : Icons.visibility_off,
                          ),
                        ),
                      ),
                      validator: (v) => v == null || v.length < 6
                          ? 'كلمة المرور لازم 6 أحرف على الأقل'
                          : null,
                    ),
                    if (isLogin)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: resetPassword,
                          child: const Text('نسيت كلمة المرور؟'),
                        ),
                      ),
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      height: 53,
                      child: ElevatedButton(
                        onPressed: loading ? null : submit,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: purple,
                          foregroundColor: Colors.white,
                        ),
                        child: loading
                            ? const CircularProgressIndicator(
                                color: Colors.white,
                              )
                            : Text(
                                isLogin ? 'تسجيل الدخول' : 'إنشاء حساب',
                                style: const TextStyle(fontSize: 17),
                              ),
                      ),
                    ),
                    TextButton(
                      onPressed: loading
                          ? null
                          : () {
                              setState(() {
                                isLogin = !isLogin;
                                formKey.currentState?.reset();
                              });
                            },
                      child: Text(
                        isLogin
                            ? 'ما عندك حساب؟ أنشئ حساب جديد'
                            : 'عندك حساب؟ سجل دخولك',
                        style: const TextStyle(
                          color: purple,
                          fontWeight: FontWeight.bold,
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
    );
  }
}

InputDecoration inputDecoration(String hint, IconData icon) {
  return InputDecoration(
    hintText: hint,
    prefixIcon: Icon(icon, color: purple),
    filled: true,
    fillColor: Colors.white,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(15),
      borderSide: BorderSide.none,
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(15),
      borderSide: BorderSide(color: Colors.grey.shade200),
    ),
  );
}

// الصفحة الرئيسية
class HomePage extends StatefulWidget {
  final User user;

  const HomePage({super.key, required this.user});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int selectedIndex = 0;
  String selectedCategory = 'الكل';
  String searchText = '';
  String buyerScope = 'local';

  final categories = [
    'الكل',
    'سيارات',
    'عقارات',
    'موبايلات',
    'أثاث',
    'أجهزة',
    'ملابس',
    'أخرى',
  ];

  @override
  Widget build(BuildContext context) {
    final pages = [
      homeContent(),
      myAdsContent(),
      accountContent(),
    ];

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: Colors.white,
          title: const Text(
            'سوق ال حمادي',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 23,
              color: purple,
            ),
          ),
          actions: [
            IconButton(
              onPressed: () => showMessage('أهلاً بيك بسوق ال حمادي'),
              icon: const Icon(Icons.notifications_none),
            ),
          ],
        ),
        body: IndexedStack(
          index: selectedIndex,
          children: pages,
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: openAddAd,
          backgroundColor: purple,
          foregroundColor: Colors.white,
          icon: const Icon(Icons.add),
          label: const Text('أضف إعلان'),
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: selectedIndex,
          onDestinationSelected: (index) {
            setState(() => selectedIndex = index);
          },
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.home_outlined),
              label: 'الرئيسية',
            ),
            NavigationDestination(
              icon: Icon(Icons.campaign_outlined),
              label: 'إعلاناتي',
            ),
            NavigationDestination(
              icon: Icon(Icons.person_outline),
              label: 'حسابي',
            ),
          ],
        ),
      ),
    );
  }

  void openAddAd() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AddAdPage(user: widget.user),
      ),
    );
    if (result == true && mounted) {
      setState(() {});
      showMessage('تم نشر إعلانك بنجاح');
    }
  }

  Widget homeContent() {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: db.collection('users').doc(widget.user.uid).snapshots(),
      builder: (context, profileSnapshot) {
        if (profileSnapshot.hasError) {
          return const Center(child: Text('تعذر قراءة بيانات حسابك'));
        }
        if (profileSnapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        final profile = profileSnapshot.data?.data() ?? {};
        final myProvince = (profile['province'] ??
                profile['محافظة'] ??
                profile['governorate'] ??
                '')
            .toString()
            .trim();

        if (myProvince.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'محافظة حسابك غير محفوظة. حدّث بيانات حسابك حتى تظهر الإعلانات حسب محافظتك.',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }

        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(15),
              child: Column(
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [purple, Color(0xFF9B70F5)],
                      ),
                      borderRadius: BorderRadius.circular(22),
                    ),
                    child: const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'كلشي تريده بمكان واحد',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 23,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        SizedBox(height: 8),
                        Text(
                          'بيع واشتري بكل سهولة من سوق ال حمادي',
                          style: TextStyle(color: Colors.white),
                        ),
                        SizedBox(height: 10),
                        Icon(Icons.storefront, color: Colors.white, size: 40),
                      ],
                    ),
                  ),
                  const SizedBox(height: 15),
                  TextField(
                    onChanged: (v) => setState(() => searchText = v.trim()),
                    decoration: InputDecoration(
                      hintText: 'شنو تريد تدور عليه؟',
                      prefixIcon: const Icon(Icons.search),
                      filled: true,
                      fillColor: Colors.white,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(15),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Text(
                        'عرض الإعلانات:',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: SegmentedButton<String>(
                          segments: const [
                            ButtonSegment(
                              value: 'local',
                              label: Text('محافظتي'),
                              icon: Icon(Icons.location_on_outlined),
                            ),
                            ButtonSegment(
                              value: 'all',
                              label: Text('كل العراق'),
                              icon: Icon(Icons.public),
                            ),
                          ],
                          selected: {buyerScope},
                          onSelectionChanged: (selection) {
                            setState(() => buyerScope = selection.first);
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 42,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: categories.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 8),
                      itemBuilder: (_, i) {
                        final category = categories[i];
                        final selected = selectedCategory == category;
                        return ChoiceChip(
                          label: Text(category),
                          selected: selected,
                          selectedColor: purple,
                          labelStyle: TextStyle(
                            color: selected ? Colors.white : Colors.black87,
                          ),
                          onSelected: (_) {
                            setState(() => selectedCategory = category);
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Align(
                alignment: Alignment.centerRight,
                child: Text(
                  buyerScope == 'local'
                      ? 'أحدث الإعلانات في $myProvince'
                      : 'إعلانات كل العراق المتاحة للجميع',
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            Expanded(
              child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: db
                    .collection('ads')
                    .where('status', isEqualTo: 'active')
                    .orderBy('createdAt', descending: true)
                    .snapshots(),
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return const Center(
                      child: Text('تعذر تحميل الإعلانات'),
                    );
                  }
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  final ads = snapshot.data!.docs.where((doc) {
                    final data = doc.data();
                    final adProvince =
                        (data['province'] ?? '').toString().trim();
                    final reach = (data['reach'] ?? 'local').toString();
                    final category = data['category'] ?? '';
                    final title = (data['title'] ?? '').toString();

                    final provinceMatch = buyerScope == 'local'
                        ? adProvince == myProvince
                        : (adProvince == myProvince || reach == 'all');

                    final categoryMatch = selectedCategory == 'الكل' ||
                        category == selectedCategory;
                    final searchMatch = title
                        .toLowerCase()
                        .contains(searchText.toLowerCase());

                    return provinceMatch && categoryMatch && searchMatch;
                  }).toList();

                  if (ads.isEmpty) {
                    return const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.shopping_bag_outlined,
                            size: 60,
                            color: purple,
                          ),
                          SizedBox(height: 12),
                          Text(
                            'ماكو إعلانات حالياً',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text('جرّب تغيير القسم أو نطاق العرض'),
                        ],
                      ),
                    );
                  }

                  return GridView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: ads.length,
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      childAspectRatio: 0.68,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12,
                    ),
                    itemBuilder: (context, index) {
                      return AdCard(data: ads[index].data());
                    },
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  Widget myAdsContent() {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: db
          .collection('ads')
          .where('sellerId', isEqualTo: widget.user.uid)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Center(child: Text('تعذر تحميل إعلاناتك'));
        }
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        final ads = snapshot.data!.docs;
        if (ads.isEmpty) {
          return const Center(
            child: Text('ما عندك إعلانات بعد، أضف أول إعلان إلك'),
          );
        }

        return GridView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: ads.length,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            childAspectRatio: 0.68,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
          ),
          itemBuilder: (_, i) => AdCard(data: ads[i].data()),
        );
      },
    );
  }

  Widget accountContent() {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: db.collection('users').doc(widget.user.uid).snapshots(),
      builder: (context, snapshot) {
        final profile = snapshot.data?.data() ?? {};
        final province = (profile['province'] ??
                profile['محافظة'] ??
                profile['governorate'] ??
                'غير محددة')
            .toString();

        return Center(
          child: Padding(
            padding: const EdgeInsets.all(22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircleAvatar(
                  radius: 42,
                  backgroundColor: Color(0xFFE9E0FF),
                  child: Icon(Icons.person, size: 48, color: purple),
                ),
                const SizedBox(height: 15),
                Text(
                  widget.user.displayName ?? 'مستخدم سوق ال حمادي',
                  style: const TextStyle(
                    fontSize: 21,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(widget.user.email ?? ''),
                const SizedBox(height: 8),
                Text('المحافظة: $province'),
                const SizedBox(height: 25),
                ElevatedButton.icon(
                  onPressed: () async {
                    await FirebaseAuth.instance.signOut();
                  },
                  icon: const Icon(Icons.logout),
                  label: const Text('تسجيل الخروج'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: purple,
                    foregroundColor: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }
}

// بطاقة الإعلان
class AdCard extends StatelessWidget {
  final Map<String, dynamic> data;

  const AdCard({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final image = data['imageUrl']?.toString() ?? '';
    final title = data['title']?.toString() ?? '';
    final price = data['price']?.toString() ?? '0';
    final province = data['province']?.toString() ?? '';

    return Card(
      clipBehavior: Clip.antiAlias,
      elevation: 2,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      child: InkWell(
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => AdDetailsPage(data: data),
            ),
          );
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: image.isEmpty
                  ? const Center(
                      child: Icon(
                        Icons.image_outlined,
                        size: 55,
                        color: Colors.grey,
                      ),
                    )
                  : Image.network(
                      image,
                      width: double.infinity,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) =>
                          const Icon(Icons.broken_image, size: 50),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.all(9),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    '$price د.ع',
                    style: const TextStyle(
                      color: purple,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  Text(
                    data['category']?.toString() ?? '',
                    style: const TextStyle(
                      color: Colors.grey,
                      fontSize: 12,
                    ),
                  ),
                  if (province.isNotEmpty)
                    Text(
                      province,
                      style: const TextStyle(
                        color: Colors.grey,
                        fontSize: 11,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// تفاصيل الإعلان والتواصل مع البائع
class AdDetailsPage extends StatelessWidget {
  final Map<String, dynamic> data;

  const AdDetailsPage({super.key, required this.data});

  Future<void> contactSeller(BuildContext context) async {
    final phone = (data['phone'] ?? '').toString();
    final digits = phone.replaceAll(RegExp(r'[^0-9]'), '');
    String number = digits;

    if (number.startsWith('00')) {
      number = number.substring(2);
    } else if (number.startsWith('0')) {
      number = '964${number.substring(1)}';
    } else if (number.startsWith('7')) {
      number = '964$number';
    }

    if (number.length < 11 || !number.startsWith('964')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('رقم واتساب البائع غير صحيح')),
      );
      return;
    }

    final message = Uri.encodeComponent(
      'السلام عليكم، شفت إعلانك بسوق ال حمادي، هل المنتج بعده متوفر؟',
    );
    final uri = Uri.parse('https://wa.me/$number?text=$message');

    try {
      final opened = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!opened && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تعذر فتح واتساب')),
        );
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تعذر فتح واتساب')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('تفاصيل الإعلان')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: Image.network(
                (data['imageUrl'] ?? '').toString(),
                height: 260,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                  height: 200,
                  color: Colors.grey.shade200,
                  child: const Icon(Icons.image, size: 70),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              (data['title'] ?? '').toString(),
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '${data['price']} د.ع',
              style: const TextStyle(
                color: purple,
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 15),
            Text('القسم: ${data['category'] ?? ''}'),
            Text('المحافظة: ${data['province'] ?? 'غير محددة'}'),
            const Divider(height: 30),
            const Text(
              'وصف المنتج',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(data['description'] ?? 'لا يوجد وصف'),
            const SizedBox(height: 20),
            Text('البائع: ${data['sellerName'] ?? 'بائع'}'),
            const SizedBox(height: 10),
            Text('رقم البائع: ${data['phone'] ?? ''}'),
            const SizedBox(height: 22),
            SizedBox(
              height: 55,
              child: ElevatedButton.icon(
                onPressed: () => contactSeller(context),
                icon: const Icon(Icons.chat),
                label: const Text(
                  'تواصل مع البائع عبر واتساب',
                  style: TextStyle(fontSize: 17),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF25D366),
                  foregroundColor: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// صفحة إضافة إعلان
class AddAdPage extends StatefulWidget {
  final User user;

  const AddAdPage({super.key, required this.user});

  @override
  State<AddAdPage> createState() => _AddAdPageState();
}

class _AddAdPageState extends State<AddAdPage> {
  final formKey = GlobalKey<FormState>();
  final titleController = TextEditingController();
  final priceController = TextEditingController();
  final descriptionController = TextEditingController();
  final phoneController = TextEditingController();

  final picker = ImagePicker();

  File? selectedImage;
  String category = 'أخرى';
  String reach = 'local';
  String? sellerProvince;
  bool loading = false;

  final categories = [
    'سيارات',
    'عقارات',
    'موبايلات',
    'أثاث',
    'أجهزة',
    'ملابس',
    'أخرى',
  ];

  @override
  void initState() {
    super.initState();
    loadSellerProvince();
  }

  Future<void> loadSellerProvince() async {
    try {
      final doc = await db.collection('users').doc(widget.user.uid).get();
      final data = doc.data() ?? {};
      final province = (data['province'] ??
              data['محافظة'] ??
              data['governorate'] ??
              '')
          .toString()
          .trim();

      if (mounted && province.isNotEmpty) {
        setState(() => sellerProvince = province);
      }
    } catch (_) {
      if (mounted) showMessage('تعذر قراءة محافظة حسابك');
    }
  }

  @override
  void dispose() {
    titleController.dispose();
    priceController.dispose();
    descriptionController.dispose();
    phoneController.dispose();
    super.dispose();
  }

  Future<void> chooseImage() async {
    try {
      final image = await picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 75,
        maxWidth: 1400,
      );
      if (image != null && mounted) {
        setState(() => selectedImage = File(image.path));
      }
    } catch (_) {
      showMessage('تعذر اختيار الصورة');
    }
  }

  Future<void> publishAd() async {
    if (!formKey.currentState!.validate()) return;

    if (selectedImage == null) {
      showMessage('اختار صورة للمنتج أولاً');
      return;
    }

    setState(() => loading = true);

    try {
      final profile = await db
          .collection('users')
          .doc(widget.user.uid)
          .get();
      final profileData = profile.data() ?? {};
      final province = (profileData['province'] ??
              profileData['محافظة'] ??
              profileData['governorate'] ??
              '')
          .toString()
          .trim();

      if (province.isEmpty) {
        throw Exception(
          'محافظة حسابك غير محفوظة. حدّث بيانات حسابك أولاً.',
        );
      }

      final imageUrl = await uploadImageToImageKit(
        selectedImage!,
        widget.user,
      );

      final adRef = db.collection('ads').doc();

      await adRef.set({
        'id': adRef.id,
        'title': titleController.text.trim(),
        'price': priceController.text.trim(),
        'description': descriptionController.text.trim(),
        'category': category,
        'phone': phoneController.text.trim(),
        'imageUrl': imageUrl,
        'sellerId': widget.user.uid,
        'sellerName': widget.user.displayName ?? 'بائع',
        'sellerEmail': widget.user.email ?? '',
        'province': province,
        'reach': reach,
        'status': 'active',
        'views': 0,
        'createdAt': FieldValue.serverTimestamp(),
      });

      if (mounted) Navigator.pop(context, true);
    } on FirebaseException catch (e) {
      showMessage('خطأ Firebase: ${e.message ?? e.code}');
    } catch (e) {
      showMessage('تعذر نشر الإعلان: $e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  void showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('إضافة إعلان جديد')),
        body: Form(
          key: formKey,
          child: ListView(
            padding: const EdgeInsets.all(18),
            children: [
              GestureDetector(
                onTap: loading ? null : chooseImage,
                child: Container(
                  height: 190,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: purple),
                  ),
                  child: selectedImage == null
                      ? const Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.add_a_photo_outlined,
                              size: 55,
                              color: purple,
                            ),
                            SizedBox(height: 10),
                            Text('اضغط لاختيار صورة المنتج'),
                          ],
                        )
                      : ClipRRect(
                          borderRadius: BorderRadius.circular(18),
                          child: Image.file(
                            selectedImage!,
                            fit: BoxFit.cover,
                            width: double.infinity,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 20),
              TextFormField(
                controller: titleController,
                decoration: inputDecoration(
                  'اسم المنتج أو السلعة',
                  Icons.shopping_bag_outlined,
                ),
                validator: (v) => v == null || v.trim().isEmpty
                    ? 'اكتب اسم المنتج'
                    : null,
              ),
              const SizedBox(height: 15),
              TextFormField(
                controller: priceController,
                keyboardType: TextInputType.number,
                decoration: inputDecoration(
                  'السعر بالدينار العراقي',
                  Icons.payments_outlined,
                ),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) {
                    return 'اكتب السعر';
                  }
                  final price = double.tryParse(v.trim());
                  if (price == null || price <= 0) {
                    return 'اكتب سعراً صحيحاً';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 15),
              DropdownButtonFormField<String>(
                value: category,
                decoration: inputDecoration(
                  'القسم',
                  Icons.category_outlined,
                ),
                items: categories.map((c) {
                  return DropdownMenuItem(
                    value: c,
                    child: Text(c),
                  );
                }).toList(),
                onChanged: loading
                    ? null
                    : (v) {
                        if (v != null) setState(() => category = v);
                      },
              ),
              const SizedBox(height: 15),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.grey.shade300),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.location_on, color: purple),
                    const SizedBox(width: 10),
                    const Text('محافظة حسابك:'),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        sellerProvince ?? 'جاري تحميل المحافظة...',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          color: purple,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 15),
              DropdownButtonFormField<String>(
                value: reach,
                decoration: inputDecoration(
                  'نطاق ظهور الإعلان',
                  Icons.public,
                ),
                items: const [
                  DropdownMenuItem(
                    value: 'local',
                    child: Text('محافظتي فقط'),
                  ),
                  DropdownMenuItem(
                    value: 'all',
                    child: Text('كل العراق'),
                  ),
                ],
                onChanged: loading
                    ? null
                    : (v) {
                        if (v != null) setState(() => reach = v);
                      },
              ),
              const SizedBox(height: 10),
              const Text(
                'إعلان محافظتي يظهر داخل محافظتك فقط، أما إعلان كل العراق '
                'فيظهر للمشترين بجميع المحافظات.',
                style: TextStyle(color: Colors.grey, fontSize: 13),
              ),
              const SizedBox(height: 15),
              TextFormField(
                controller: descriptionController,
                maxLines: 4,
                decoration: inputDecoration(
                  'وصف المنتج والتفاصيل',
                  Icons.description_outlined,
                ),
                validator: (v) => v == null || v.trim().isEmpty
                    ? 'اكتب وصف المنتج'
                    : null,
              ),
              const SizedBox(height: 15),
              TextFormField(
                controller: phoneController,
                keyboardType: TextInputType.phone,
                decoration: inputDecoration(
                  'رقم واتساب البائع (مثلاً 07xxxxxxxxx)',
                  Icons.phone_android,
                ),
                validator: (v) {
                  final digits = (v ?? '').replaceAll(
                    RegExp(r'[^0-9]'),
                    '',
                  );
                  if (digits.length < 10 || digits.length > 15) {
                    return 'اكتب رقم هاتف صحيح';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 25),
              SizedBox(
                height: 55,
                child: ElevatedButton.icon(
                  onPressed: loading ? null : publishAd,
                  icon: loading
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.publish),
                  label: Text(
                    loading ? 'جاري النشر...' : 'انشر الإعلان',
                    style: const TextStyle(fontSize: 18),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: purple,
                    foregroundColor: Colors.white,
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
