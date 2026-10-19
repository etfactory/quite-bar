# 외부 코드 및 참고 자료

## Hidden Bar

프로젝트: https://github.com/dwarvesf/hidden

참고 버전: `v1.11.1`, 네이티브 엔진 커밋 `546892a7508dd08dc2782de7e6429963f0d7e78f`.

`Native/VisibilityBridge.m`의 런타임 인터페이스는 Hidden Bar의 `HBNativeVisibilityShim.m`에 공개된 클래스·selector, 배열 구성 및 예외 처리 방식을 참고·변형했습니다. AXExtrasMenuBar를 통한 위치 조사 및 앱 단위 제어 제약도 해당 구현을 참고했습니다. 원본 UI 리소스, 아이콘, 스토리보드 및 원본 앱 번들 식별자는 사용하지 않습니다.

원본 라이선스: [MIT](https://github.com/dwarvesf/hidden/blob/v1.11.1/LICENSE).

```text
MIT License

Copyright (c) 2019 Dwarves Foundation

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

SwiftUI、AppKit、SF Symbols 등 Apple SDK 구성 요소에는 Apple의 각 사용 조건이 적용됩니다. Apple의 비공개 프레임워크는 앱에 복사하거나 재배포하지 않고 설치된 OS에서 런타임으로 찾습니다.
