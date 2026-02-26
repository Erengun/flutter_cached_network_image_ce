import 'dart:io';

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blurhash/flutter_blurhash.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'benchmark_page.dart';

void main() {
  CachedNetworkImage.logLevel = CacheManagerLogLevel.debug;
  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CachedNetworkImage CE Demo',
      theme: ThemeData(
        colorSchemeSeed: Colors.blue,
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('CachedNetworkImage CE'),
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.image), text: 'Basic'),
              Tab(icon: Icon(Icons.list), text: 'List'),
              Tab(icon: Icon(Icons.grid_on), text: 'Grid'),
              Tab(icon: Icon(Icons.speed), text: 'Benchmark'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            BasicContent(),
            ListContent(),
            GridContent(),
            BenchmarkContent(),
          ],
        ),
      ),
    );
  }
}

/// Demonstrates a [StatelessWidget] containing [CachedNetworkImage]
class BasicContent extends StatelessWidget {
  const BasicContent({super.key});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            _blurHashImage(),
            _sizedContainer(
              CachedNetworkImage(
                imageUrl:
                    'https://upload.wikimedia.org/wikipedia/commons/0/02/SVG_logo.svg',
                placeholder: (context, url) =>
                    const CircularProgressIndicator(),
                unsupportedImageBuilder: (context, url, bytes) =>
                    SvgPicture.memory(
                  bytes,
                  fit: BoxFit.contain,
                ),
                errorBuilder: (context, error, stackTrace) =>
                    const Icon(Icons.error),
              ),
            ),
            _sizedContainer(
              const Image(
                width: double.infinity,
                fit: BoxFit.fitWidth,
                image: CachedNetworkImageProvider(
                  'https://images.unsplash.com/photo-1614517453351-6c1522fc7a56',
                ),
              ),
              width: double.infinity,
              height: 200,
            ),
            _sizedContainer(
              CachedNetworkImage(
                progressIndicatorBuilder: (context, url, progress) => Center(
                  child: CircularProgressIndicator(
                    value: progress.progress,
                  ),
                ),
                imageUrl:
                    'https://images.unsplash.com/photo-1532264523420-881a47db012d?ixlib=rb-1.2.1&ixid=eyJhcHBfaWQiOjEyMDd9',
              ),
            ),
            _sizedContainer(
              CachedNetworkImage(
                placeholder: (context, url) =>
                    const CircularProgressIndicator(),
                imageUrl:
                    'https://plus.unsplash.com/premium_photo-1695566086196-1cdadbaa1988?q=80&w=1470&auto=format&fit=crop&ixlib=rb-4.1.0&ixid=M3wxMjA3fDB8MHxwaG90by1wYWdlfHx8fGVufDB8fHx8fA%3D%3D',
              ),
            ),
            _sizedContainer(
              CachedNetworkImage(
                imageUrl:
                    'https://images.unsplash.com/photo-1644588815329-4705c4418d38?q=80&w=1473&auto=format&fit=crop&ixlib=rb-4.1.0&ixid=M3wxMjA3fDB8MHxwaG90by1wYWdlfHx8fGVufDB8fHx8fA%3D%3D',
                imageBuilder: (context, imageProvider) => Container(
                  decoration: BoxDecoration(
                    image: DecorationImage(
                      image: imageProvider,
                      fit: BoxFit.cover,
                      colorFilter: const ColorFilter.mode(
                        Colors.red,
                        BlendMode.colorBurn,
                      ),
                    ),
                  ),
                ),
                placeholder: (context, url) =>
                    const CircularProgressIndicator(),
                errorBuilder: (context, error, stackTrace) =>
                    const Icon(Icons.error),
              ),
            ),
            CachedNetworkImage(
              imageUrl:
                  'https://images.unsplash.com/photo-1565343486673-fbd3a3ce9331?q=80&w=1471&auto=format&fit=crop&ixlib=rb-4.1.0&ixid=M3wxMjA3fDB8MHxwaG90by1wYWdlfHx8fGVufDB8fHx8fA%3D%3D',
              placeholder: (context, url) => const CircleAvatar(
                backgroundColor: Colors.amber,
                radius: 150,
              ),
              imageBuilder: (context, image) => CircleAvatar(
                backgroundImage: image,
                radius: 150,
              ),
            ),
            _sizedContainer(
              CachedNetworkImage(
                errorBuilder: (context, error, stackTrace) =>
                    const Icon(Icons.error),
                placeholder: (context, url) =>
                    const CircularProgressIndicator(),
                imageUrl: 'not a valid uri',
              ),
            ),
            _sizedContainer(
              CachedNetworkImage(
                imageUrl: 'not a uri at all',
                placeholder: (context, url) =>
                    const CircularProgressIndicator(),
                errorBuilder: (context, error, stackTrace) =>
                    const Icon(Icons.error),
                errorListener: (e) {
                  if (e is SocketException) {
                    debugPrint(
                        'Error with ${e.address} and message ${e.message}');
                  } else {
                    debugPrint('Image Exception is: ${e.runtimeType}');
                  }
                },
              ),
            ),
            _sizedContainer(
              CachedNetworkImage(
                maxHeightDiskCache: 10,
                imageUrl:
                    'https://images.unsplash.com/photo-1706212074955-6045fce2521d?q=80&w=1470&auto=format&fit=crop&ixlib=rb-4.1.0&ixid=M3wxMjA3fDB8MHxwaG90by1wYWdlfHx8fGVufDB8fHx8fA%3D%3D',
                placeholder: (context, url) =>
                    const CircularProgressIndicator(),
                errorBuilder: (context, error, stackTrace) =>
                    const Icon(Icons.error),
                fadeInDuration: const Duration(seconds: 3),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _blurHashImage() {
    return SizedBox(
      width: double.infinity,
      child: CachedNetworkImage(
        placeholder: (context, url) => const AspectRatio(
          aspectRatio: 1.6,
          child: BlurHash(hash: 'LEHV6nWB2yk8pyo0adR*.7kCMdnj'),
        ),
        imageUrl: 'https://blurha.sh/12c2aca29ea896a628be.jpg',
        fit: BoxFit.cover,
      ),
    );
  }

  Widget _sizedContainer(Widget child,
      {double width = double.infinity, double height = 250}) {
    return SizedBox(
      width: width,
      height: height,
      child: Center(child: child),
    );
  }
}

/// Demonstrates a [ListView] containing [CachedNetworkImage]
class ListContent extends StatelessWidget {
  const ListContent({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      itemBuilder: (BuildContext context, int index) => Card(
        child: Column(
          children: <Widget>[
            CachedNetworkImage(
              imageUrl: 'https://loremflickr.com/320/240/music?lock=$index',
              placeholder: (BuildContext context, String url) => Container(
                width: 320,
                height: 240,
                color: Colors.purple,
              ),
            ),
          ],
        ),
      ),
      itemCount: 250,
    );
  }
}

/// Demonstrates a [GridView] containing [CachedNetworkImage]
class GridContent extends StatelessWidget {
  const GridContent({super.key});

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      itemCount: 250,
      gridDelegate:
          const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3),
      itemBuilder: (BuildContext context, int index) => CachedNetworkImage(
        imageUrl: 'https://loremflickr.com/100/100/music?lock=$index',
        placeholder: _loader,
        errorBuilder: _error,
      ),
    );
  }

  Widget _loader(BuildContext context, String url) {
    return const Center(child: CircularProgressIndicator());
  }

  Widget _error(BuildContext context, Object error, StackTrace? stackTrace) {
    return const Center(child: Icon(Icons.error));
  }
}
