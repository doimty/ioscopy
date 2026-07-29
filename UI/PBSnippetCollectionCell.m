#import "PBSnippetCollectionCell.h"
#import "PBAppIconProvider.h"
#import "../Shared/PBLocalization.h"
#import <ImageIO/ImageIO.h>

static NSCache<NSString *, UIImage *> *PBThumbnailCache(void) {
    static NSCache<NSString *, UIImage *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[NSCache alloc] init];
        cache.name = @"com.ssdsl.ioscopy.thumbnails";
        cache.countLimit = 96;
        cache.totalCostLimit = 36 * 1024 * 1024;
    });
    return cache;
}

static dispatch_queue_t PBThumbnailDecodeQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.ssdsl.ioscopy.thumbnail-decode",
                                      DISPATCH_QUEUE_CONCURRENT);
    });
    return queue;
}

static UIImage *PBDecodedThumbnailImageAtPath(NSString *path, CGFloat scale) {
    if (path.length == 0) {
        return nil;
    }

    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!source) {
        return nil;
    }

    NSDictionary *options = @{
        (__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform: @YES,
        (__bridge NSString *)kCGImageSourceShouldCacheImmediately: @YES,
        (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize: @720
    };
    CGImageRef imageRef = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
    CFRelease(source);
    if (!imageRef) {
        return nil;
    }

    UIImage *image = [UIImage imageWithCGImage:imageRef
                                         scale:scale
                                   orientation:UIImageOrientationUp];
    CGImageRelease(imageRef);
    return image;
}

@interface PBSnippetCollectionCell () <UIGestureRecognizerDelegate>
@property (nonatomic, strong) UIView *cardView;
@property (nonatomic, strong) UIView *swipeActionContainerView;
@property (nonatomic, strong) UIView *mediaContainerView;
@property (nonatomic, strong) UILabel *appNameLabel;
@property (nonatomic, strong) UILabel *timeLabel;
@property (nonatomic, strong) UILabel *contentLabel;
@property (nonatomic, strong) UIImageView *thumbnailImageView;
@property (nonatomic, strong) UIImageView *sourceIconView;
@property (nonatomic, strong) UIStackView *actionStackView;
@property (nonatomic, strong) UIButton *pinButton;
@property (nonatomic, strong) UIButton *favoriteButton;
@property (nonatomic, strong) UIButton *deleteButton;
@property (nonatomic, strong) UIButton *swipePinButton;
@property (nonatomic, strong) UIButton *swipeFavoriteButton;
@property (nonatomic, strong) UIButton *swipeDeleteButton;
@property (nonatomic, strong) UILabel *sizeLabel;
@property (nonatomic, assign) BOOL usesVerticalLayout;
@property (nonatomic, assign) CGFloat swipeOffset;
@property (nonatomic, assign) CGFloat swipeStartOffset;
@property (nonatomic, strong) UIPanGestureRecognizer *swipePanGestureRecognizer;
@property (nonatomic, strong) NSArray<NSLayoutConstraint *> *horizontalLayoutConstraints;
@property (nonatomic, strong) NSArray<NSLayoutConstraint *> *verticalLayoutConstraints;
@end

static CGFloat const kPBHorizontalSourceIconSize = 34.0;
static CGFloat const kPBVerticalSourceIconSize = 28.0;
static CGFloat const kPBHorizontalActionButtonSize = 26.0;
static CGFloat const kPBSwipeActionWidth = 144.0;

@implementation PBSnippetCollectionCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self setupUI];
    }
    return self;
}

- (void)setupUI {
    self.backgroundColor = [UIColor clearColor];
    self.contentView.backgroundColor = [UIColor clearColor];

    _swipeActionContainerView = [[UIView alloc] init];
    _swipeActionContainerView.translatesAutoresizingMaskIntoConstraints = NO;
    _swipeActionContainerView.layer.cornerRadius = 10;
    _swipeActionContainerView.clipsToBounds = YES;
    _swipeActionContainerView.hidden = YES;
    [self.contentView addSubview:_swipeActionContainerView];

    _swipePinButton = [self swipeActionButtonWithImageName:@"pin" backgroundColor:[UIColor systemOrangeColor]];
    [_swipePinButton addTarget:self action:@selector(swipePinButtonTapped) forControlEvents:UIControlEventTouchUpInside];

    _swipeFavoriteButton = [self swipeActionButtonWithImageName:@"star" backgroundColor:[UIColor systemYellowColor]];
    [_swipeFavoriteButton addTarget:self action:@selector(swipeFavoriteButtonTapped) forControlEvents:UIControlEventTouchUpInside];

    _swipeDeleteButton = [self swipeActionButtonWithImageName:@"trash" backgroundColor:[UIColor systemRedColor]];
    [_swipeDeleteButton addTarget:self action:@selector(swipeDeleteButtonTapped) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *swipeActionStackView = [[UIStackView alloc] initWithArrangedSubviews:@[
        _swipePinButton,
        _swipeFavoriteButton,
        _swipeDeleteButton
    ]];
    swipeActionStackView.translatesAutoresizingMaskIntoConstraints = NO;
    swipeActionStackView.axis = UILayoutConstraintAxisHorizontal;
    swipeActionStackView.alignment = UIStackViewAlignmentFill;
    swipeActionStackView.distribution = UIStackViewDistributionFillEqually;
    swipeActionStackView.spacing = 0;
    [_swipeActionContainerView addSubview:swipeActionStackView];

    _cardView = [[UIView alloc] init];
    _cardView.translatesAutoresizingMaskIntoConstraints = NO;
    _cardView.layer.cornerRadius = 10;
    _cardView.layer.masksToBounds = YES;
    _cardView.layer.borderWidth = 1.0 / [UIScreen mainScreen].scale;
    _cardView.layer.borderColor = [[UIColor separatorColor] colorWithAlphaComponent:0.35].CGColor;
    if (@available(iOS 13.0, *)) {
        _cardView.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    } else {
        _cardView.backgroundColor = [UIColor whiteColor];
    }
    [self.contentView addSubview:_cardView];

    _mediaContainerView = [[UIView alloc] init];
    _mediaContainerView.translatesAutoresizingMaskIntoConstraints = NO;
    _mediaContainerView.layer.cornerRadius = 8;
    _mediaContainerView.clipsToBounds = YES;
    if (@available(iOS 13.0, *)) {
        _mediaContainerView.backgroundColor = [UIColor systemFillColor];
    } else {
        _mediaContainerView.backgroundColor = [UIColor colorWithWhite:0.92 alpha:1.0];
    }
    [_cardView addSubview:_mediaContainerView];

    _sourceIconView = [[UIImageView alloc] init];
    _sourceIconView.translatesAutoresizingMaskIntoConstraints = NO;
    _sourceIconView.contentMode = UIViewContentModeScaleAspectFit;
    _sourceIconView.layer.cornerRadius = 7;
    _sourceIconView.clipsToBounds = YES;
    _sourceIconView.backgroundColor = [UIColor clearColor];
    _sourceIconView.tintColor = [UIColor systemBlueColor];
    [_cardView addSubview:_sourceIconView];

    _appNameLabel = [[UILabel alloc] init];
    _appNameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _appNameLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    _appNameLabel.textColor = [UIColor labelColor];
    _appNameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [_appNameLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                                   forAxis:UILayoutConstraintAxisHorizontal];
    [_cardView addSubview:_appNameLabel];

    _timeLabel = [[UILabel alloc] init];
    _timeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _timeLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
    _timeLabel.textColor = [UIColor tertiaryLabelColor];
    [_timeLabel setContentCompressionResistancePriority:UILayoutPriorityRequired
                                                forAxis:UILayoutConstraintAxisHorizontal];
    [_cardView addSubview:_timeLabel];

    _pinButton = [self actionButtonWithImageName:@"pin"];
    [_pinButton addTarget:self action:@selector(pinButtonTapped) forControlEvents:UIControlEventTouchUpInside];

    _favoriteButton = [self actionButtonWithImageName:@"star"];
    [_favoriteButton addTarget:self action:@selector(favoriteButtonTapped) forControlEvents:UIControlEventTouchUpInside];

    _deleteButton = [self actionButtonWithImageName:@"trash"];
    _deleteButton.tintColor = [UIColor systemRedColor];
    [_deleteButton addTarget:self action:@selector(deleteButtonTapped) forControlEvents:UIControlEventTouchUpInside];

    _actionStackView = [[UIStackView alloc] initWithArrangedSubviews:@[
        _pinButton,
        _favoriteButton,
        _deleteButton
    ]];
    _actionStackView.translatesAutoresizingMaskIntoConstraints = NO;
    _actionStackView.axis = UILayoutConstraintAxisHorizontal;
    _actionStackView.alignment = UIStackViewAlignmentCenter;
    _actionStackView.distribution = UIStackViewDistributionFillEqually;
    _actionStackView.spacing = 4;
    [_cardView addSubview:_actionStackView];

    _contentLabel = [[UILabel alloc] init];
    _contentLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _contentLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    _contentLabel.textColor = [UIColor secondaryLabelColor];
    _contentLabel.numberOfLines = 2;
    _contentLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [_cardView addSubview:_contentLabel];

    _thumbnailImageView = [[UIImageView alloc] init];
    _thumbnailImageView.translatesAutoresizingMaskIntoConstraints = NO;
    _thumbnailImageView.contentMode = UIViewContentModeScaleAspectFit;
    _thumbnailImageView.layer.cornerRadius = 7;
    _thumbnailImageView.clipsToBounds = YES;
    _thumbnailImageView.hidden = YES;
    [_mediaContainerView addSubview:_thumbnailImageView];

    _sizeLabel = [[UILabel alloc] init];
    _sizeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _sizeLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
    _sizeLabel.textColor = [UIColor tertiaryLabelColor];
    _sizeLabel.textAlignment = NSTextAlignmentRight;
    _sizeLabel.hidden = YES;
    [_cardView addSubview:_sizeLabel];

    NSArray<NSLayoutConstraint *> *commonConstraints = @[
        [_cardView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:3],
        [_cardView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-3],
        [_cardView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [_cardView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],

        [_swipeActionContainerView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:3],
        [_swipeActionContainerView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-3],
        [_swipeActionContainerView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        [_swipeActionContainerView.widthAnchor constraintEqualToConstant:kPBSwipeActionWidth],

        [swipeActionStackView.topAnchor constraintEqualToAnchor:_swipeActionContainerView.topAnchor],
        [swipeActionStackView.bottomAnchor constraintEqualToAnchor:_swipeActionContainerView.bottomAnchor],
        [swipeActionStackView.leadingAnchor constraintEqualToAnchor:_swipeActionContainerView.leadingAnchor],
        [swipeActionStackView.trailingAnchor constraintEqualToAnchor:_swipeActionContainerView.trailingAnchor],

        [_thumbnailImageView.topAnchor constraintEqualToAnchor:_mediaContainerView.topAnchor constant:4],
        [_thumbnailImageView.bottomAnchor constraintEqualToAnchor:_mediaContainerView.bottomAnchor constant:-4],
        [_thumbnailImageView.leadingAnchor constraintEqualToAnchor:_mediaContainerView.leadingAnchor constant:4],
        [_thumbnailImageView.trailingAnchor constraintEqualToAnchor:_mediaContainerView.trailingAnchor constant:-4],

        [_contentLabel.trailingAnchor constraintEqualToAnchor:_cardView.trailingAnchor constant:-12],

        [_sizeLabel.trailingAnchor constraintEqualToAnchor:_cardView.trailingAnchor constant:-14],
        [_sizeLabel.bottomAnchor constraintEqualToAnchor:_cardView.bottomAnchor constant:-10],
    ];

    self.horizontalLayoutConstraints = @[
        [_sourceIconView.widthAnchor constraintEqualToConstant:kPBHorizontalSourceIconSize],
        [_sourceIconView.heightAnchor constraintEqualToConstant:kPBHorizontalSourceIconSize],
        [_sourceIconView.topAnchor constraintEqualToAnchor:_cardView.topAnchor constant:10],
        [_sourceIconView.trailingAnchor constraintEqualToAnchor:_cardView.trailingAnchor constant:-10],

        [_pinButton.widthAnchor constraintEqualToConstant:kPBHorizontalActionButtonSize],
        [_pinButton.heightAnchor constraintEqualToConstant:kPBHorizontalActionButtonSize],
        [_favoriteButton.widthAnchor constraintEqualToConstant:kPBHorizontalActionButtonSize],
        [_favoriteButton.heightAnchor constraintEqualToConstant:kPBHorizontalActionButtonSize],
        [_deleteButton.widthAnchor constraintEqualToConstant:kPBHorizontalActionButtonSize],
        [_deleteButton.heightAnchor constraintEqualToConstant:kPBHorizontalActionButtonSize],

        [_mediaContainerView.topAnchor constraintEqualToAnchor:_sourceIconView.bottomAnchor constant:9],
        [_mediaContainerView.leadingAnchor constraintEqualToAnchor:_cardView.leadingAnchor constant:12],
        [_mediaContainerView.trailingAnchor constraintEqualToAnchor:_cardView.trailingAnchor constant:-12],
        [_mediaContainerView.bottomAnchor constraintEqualToAnchor:_sizeLabel.topAnchor constant:-5],

        [_appNameLabel.topAnchor constraintEqualToAnchor:_cardView.topAnchor constant:10],
        [_appNameLabel.leadingAnchor constraintEqualToAnchor:_cardView.leadingAnchor constant:12],
        [_appNameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_actionStackView.leadingAnchor constant:-8],

        [_timeLabel.topAnchor constraintEqualToAnchor:_appNameLabel.bottomAnchor constant:2],
        [_timeLabel.leadingAnchor constraintEqualToAnchor:_appNameLabel.leadingAnchor],
        [_timeLabel.trailingAnchor constraintEqualToAnchor:_actionStackView.leadingAnchor constant:-4],

        [_actionStackView.widthAnchor constraintEqualToConstant:86],
        [_actionStackView.heightAnchor constraintEqualToConstant:30],
        [_actionStackView.centerYAnchor constraintEqualToAnchor:_sourceIconView.centerYAnchor],
        [_actionStackView.trailingAnchor constraintEqualToAnchor:_sourceIconView.leadingAnchor constant:-6],

        [_contentLabel.topAnchor constraintEqualToAnchor:_sourceIconView.bottomAnchor constant:10],
        [_contentLabel.leadingAnchor constraintEqualToAnchor:_cardView.leadingAnchor constant:12],
        [_contentLabel.bottomAnchor constraintLessThanOrEqualToAnchor:_cardView.bottomAnchor constant:-10],
    ];

    self.verticalLayoutConstraints = @[
        [_sourceIconView.widthAnchor constraintEqualToConstant:kPBVerticalSourceIconSize],
        [_sourceIconView.heightAnchor constraintEqualToConstant:kPBVerticalSourceIconSize],

        [_mediaContainerView.leadingAnchor constraintEqualToAnchor:_cardView.leadingAnchor constant:12],
        [_mediaContainerView.centerYAnchor constraintEqualToAnchor:_cardView.centerYAnchor],
        [_mediaContainerView.widthAnchor constraintEqualToConstant:56],
        [_mediaContainerView.heightAnchor constraintEqualToConstant:48],

        [_sourceIconView.centerXAnchor constraintEqualToAnchor:_mediaContainerView.centerXAnchor],
        [_sourceIconView.centerYAnchor constraintEqualToAnchor:_mediaContainerView.centerYAnchor],

        [_appNameLabel.topAnchor constraintEqualToAnchor:_cardView.topAnchor constant:6],
        [_appNameLabel.leadingAnchor constraintEqualToAnchor:_mediaContainerView.trailingAnchor constant:10],

        [_timeLabel.centerYAnchor constraintEqualToAnchor:_appNameLabel.centerYAnchor],
        [_timeLabel.leadingAnchor constraintEqualToAnchor:_appNameLabel.trailingAnchor constant:6],
        [_timeLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_cardView.trailingAnchor constant:-12],

        [_contentLabel.topAnchor constraintEqualToAnchor:_timeLabel.bottomAnchor constant:4],
        [_contentLabel.leadingAnchor constraintEqualToAnchor:_appNameLabel.leadingAnchor],
        [_contentLabel.bottomAnchor constraintLessThanOrEqualToAnchor:_cardView.bottomAnchor constant:-4],
    ];

    _swipePanGestureRecognizer = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                         action:@selector(handleSwipePan:)];
    _swipePanGestureRecognizer.delegate = self;
    [self.contentView addGestureRecognizer:_swipePanGestureRecognizer];

    [NSLayoutConstraint activateConstraints:commonConstraints];
    [self setUsesVerticalLayout:NO];
}

- (UIButton *)actionButtonWithImageName:(NSString *)imageName {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setImage:[UIImage systemImageNamed:imageName] forState:UIControlStateNormal];
    button.tintColor = [UIColor tertiaryLabelColor];
    button.contentEdgeInsets = UIEdgeInsetsMake(3, 3, 3, 3);
    button.adjustsImageWhenHighlighted = YES;
    return button;
}

- (UIButton *)swipeActionButtonWithImageName:(NSString *)imageName backgroundColor:(UIColor *)backgroundColor {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setImage:[UIImage systemImageNamed:imageName] forState:UIControlStateNormal];
    button.tintColor = [UIColor whiteColor];
    button.backgroundColor = backgroundColor;
    button.contentEdgeInsets = UIEdgeInsetsMake(14, 14, 14, 14);
    button.adjustsImageWhenHighlighted = YES;
    return button;
}

- (UIColor *)standaloneIconBackgroundColor {
    if (@available(iOS 13.0, *)) {
        return [UIColor secondarySystemFillColor];
    }
    return [UIColor colorWithWhite:0.9 alpha:1.0];
}

- (void)setUsesVerticalLayout:(BOOL)usesVerticalLayout {
    _usesVerticalLayout = usesVerticalLayout;
    [NSLayoutConstraint deactivateConstraints:self.horizontalLayoutConstraints];
    [NSLayoutConstraint deactivateConstraints:self.verticalLayoutConstraints];
    [NSLayoutConstraint activateConstraints:usesVerticalLayout
        ? self.verticalLayoutConstraints
        : self.horizontalLayoutConstraints];

    self.contentLabel.numberOfLines = usesVerticalLayout ? 2 : 0;
    self.contentLabel.font = usesVerticalLayout
        ? [UIFont systemFontOfSize:12 weight:UIFontWeightRegular]
        : [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    self.thumbnailImageView.contentMode = usesVerticalLayout
        ? UIViewContentModeScaleAspectFit
        : UIViewContentModeScaleAspectFill;
    self.sourceIconView.backgroundColor = usesVerticalLayout
        ? [UIColor clearColor]
        : [self standaloneIconBackgroundColor];
    self.actionStackView.hidden = usesVerticalLayout;
    self.actionStackView.spacing = 4;
    self.swipeActionContainerView.hidden = !usesVerticalLayout;
    self.swipePanGestureRecognizer.enabled = usesVerticalLayout;
    [self closeSwipeActionsAnimated:NO];
    [self setNeedsUpdateConstraints];
    [self setNeedsLayout];
}

- (void)configureWithItem:(PBClipboardItem *)item {
    self.item = item;

    self.appNameLabel.text = item.sourceAppName.length > 0 ? item.sourceAppName : PBLocalizedString(@"Unknown");
    self.timeLabel.text = [item relativeTimeString];

    NSString *pinName = item.isPinned ? @"pin.fill" : @"pin";
    UIColor *pinColor = item.isPinned ? [UIColor systemOrangeColor] : [UIColor tertiaryLabelColor];
    [self.pinButton setImage:[UIImage systemImageNamed:pinName] forState:UIControlStateNormal];
    self.pinButton.tintColor = pinColor;
    [self.swipePinButton setImage:[UIImage systemImageNamed:pinName] forState:UIControlStateNormal];

    NSString *starName = item.isFavorite ? @"star.fill" : @"star";
    UIColor *starColor = item.isFavorite ? [UIColor systemYellowColor] : [UIColor tertiaryLabelColor];
    [self.favoriteButton setImage:[UIImage systemImageNamed:starName] forState:UIControlStateNormal];
    self.favoriteButton.tintColor = starColor;
    [self.swipeFavoriteButton setImage:[UIImage systemImageNamed:starName] forState:UIControlStateNormal];
    self.deleteButton.tintColor = [UIColor systemRedColor];
    [self.swipeDeleteButton setImage:[UIImage systemImageNamed:@"trash"] forState:UIControlStateNormal];

    if (item.contentType == PBContentTypeImage && item.thumbnailPath.length > 0) {
        self.contentLabel.hidden = !self.usesVerticalLayout;
        self.contentLabel.text = [item contentPreview];
        self.contentLabel.textColor = [UIColor secondaryLabelColor];
        self.mediaContainerView.hidden = NO;
        self.thumbnailImageView.hidden = NO;
        self.sourceIconView.hidden = self.usesVerticalLayout;
        self.sizeLabel.hidden = self.usesVerticalLayout;
        NSString *thumbnailPath = [item.thumbnailPath copy];
        UIImage *cachedThumbnail = [PBThumbnailCache() objectForKey:thumbnailPath];
        self.thumbnailImageView.image = cachedThumbnail;

        if (!cachedThumbnail) {
            NSInteger configuredItemId = item.itemId;
            CGFloat scale = [UIScreen mainScreen].scale;
            __weak typeof(self) weakSelf = self;
            dispatch_async(PBThumbnailDecodeQueue(), ^{
                UIImage *thumbnail = PBDecodedThumbnailImageAtPath(thumbnailPath, scale);
                if (thumbnail) {
                    NSUInteger cost =
                        (NSUInteger)(thumbnail.size.width * thumbnail.scale *
                                     thumbnail.size.height * thumbnail.scale * 4.0);
                    [PBThumbnailCache() setObject:thumbnail forKey:thumbnailPath cost:cost];
                }

                dispatch_async(dispatch_get_main_queue(), ^{
                    __strong typeof(weakSelf) strongSelf = weakSelf;
                    if (!strongSelf ||
                        strongSelf.item.itemId != configuredItemId ||
                        ![strongSelf.item.thumbnailPath isEqualToString:thumbnailPath]) {
                        return;
                    }
                    strongSelf.thumbnailImageView.image = thumbnail;
                });
            });
        }

        CGFloat sizeKB = item.dataSize / 1024.0;
        if (sizeKB > 1024) {
            self.sizeLabel.text = [NSString stringWithFormat:@"%.1f MB", sizeKB / 1024.0];
        } else {
            self.sizeLabel.text = [NSString stringWithFormat:@"%.0f KB", sizeKB];
        }
    } else {
        self.contentLabel.hidden = NO;
        self.mediaContainerView.hidden = !self.usesVerticalLayout;
        self.thumbnailImageView.hidden = YES;
        self.sourceIconView.hidden = NO;
        self.sizeLabel.hidden = YES;
        self.thumbnailImageView.image = nil;
        self.contentLabel.text = [item contentPreview];
        self.contentLabel.textColor = item.contentType == PBContentTypeURL
            ? [UIColor systemBlueColor]
            : [UIColor secondaryLabelColor];
    }

    PBAppIconProvider *iconProvider = [PBAppIconProvider sharedProvider];
    CGFloat preferredIconSize = self.usesVerticalLayout ? kPBVerticalSourceIconSize : kPBHorizontalSourceIconSize;
    self.sourceIconView.image = [iconProvider iconForItem:item preferredSize:preferredIconSize];

    NSInteger configuredItemId = item.itemId;
    NSString *configuredBundleId = [item.sourceBundleId copy];
    __weak typeof(self) weakSelf = self;
    [iconProvider loadIconForItem:item preferredSize:preferredIconSize completion:^(UIImage *icon) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.item.itemId != configuredItemId) {
            return;
        }

        NSString *currentBundleId = strongSelf.item.sourceBundleId ?: @"";
        if (![currentBundleId isEqualToString:configuredBundleId ?: @""]) {
            return;
        }

        strongSelf.sourceIconView.image = icon;
    }];
}

- (void)pinButtonTapped {
    [self.delegate snippetCellDidTapPin:self];
}

- (void)swipePinButtonTapped {
    [self closeSwipeActionsAnimated:YES];
    [self.delegate snippetCellDidTapPin:self];
}

- (void)favoriteButtonTapped {
    [self.delegate snippetCellDidTapFavorite:self];
}

- (void)swipeFavoriteButtonTapped {
    [self closeSwipeActionsAnimated:YES];
    [self.delegate snippetCellDidTapFavorite:self];
}

- (void)deleteButtonTapped {
    [self.delegate snippetCellDidTapDelete:self];
}

- (void)swipeDeleteButtonTapped {
    [self closeSwipeActionsAnimated:NO];
    [self.delegate snippetCellDidTapDelete:self];
}

- (void)handleSwipePan:(UIPanGestureRecognizer *)gestureRecognizer {
    if (!self.usesVerticalLayout) {
        return;
    }

    switch (gestureRecognizer.state) {
        case UIGestureRecognizerStateBegan:
            self.swipeStartOffset = self.swipeOffset;
            break;
        case UIGestureRecognizerStateChanged: {
            CGFloat proposedOffset = self.swipeStartOffset +
                [gestureRecognizer translationInView:self.contentView].x;
            [self updateSwipeOffset:proposedOffset animated:NO];
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled: {
            CGFloat velocityX = [gestureRecognizer velocityInView:self.contentView].x;
            BOOL shouldOpen = self.swipeOffset < -kPBSwipeActionWidth * 0.45;
            if (velocityX < -260.0) {
                shouldOpen = YES;
            } else if (velocityX > 260.0) {
                shouldOpen = NO;
            }

            shouldOpen ? [self openSwipeActionsAnimated:YES] : [self closeSwipeActionsAnimated:YES];
            break;
        }
        default:
            break;
    }
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer != self.swipePanGestureRecognizer || !self.usesVerticalLayout) {
        return YES;
    }

    CGPoint velocity = [(UIPanGestureRecognizer *)gestureRecognizer velocityInView:self.contentView];
    return fabs(velocity.x) > fabs(velocity.y);
}

- (void)openSwipeActionsAnimated:(BOOL)animated {
    if (!self.usesVerticalLayout) {
        return;
    }
    [self updateSwipeOffset:-kPBSwipeActionWidth animated:animated];
}

- (void)closeSwipeActionsAnimated:(BOOL)animated {
    [self updateSwipeOffset:0 animated:animated];
}

- (void)updateSwipeOffset:(CGFloat)offset animated:(BOOL)animated {
    CGFloat clampedOffset = MIN(0.0, MAX(-kPBSwipeActionWidth, offset));
    self.swipeOffset = clampedOffset;
    BOOL shouldShowActions = self.usesVerticalLayout && clampedOffset < -0.5;
    if (shouldShowActions) {
        self.swipeActionContainerView.hidden = NO;
    }

    void (^animations)(void) = ^{
        [self applyCardTransform];
    };

    void (^completion)(BOOL) = ^(BOOL finished) {
        if (!shouldShowActions) {
            self.swipeActionContainerView.hidden = YES;
        }
    };

    if (animated) {
        [UIView animateWithDuration:0.2
                              delay:0
             usingSpringWithDamping:0.92
              initialSpringVelocity:0
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:animations
                         completion:completion];
    } else {
        animations();
        completion(YES);
    }
}

- (void)applyCardTransform {
    CGAffineTransform transform = CGAffineTransformMakeTranslation(self.swipeOffset, 0);
    if (self.highlighted) {
        transform = CGAffineTransformScale(transform, 0.97, 0.97);
    }
    self.cardView.transform = transform;
    self.cardView.alpha = self.highlighted ? 0.82 : 1.0;
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];

    [UIView animateWithDuration:0.15 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        [self applyCardTransform];
    } completion:nil];
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.mediaContainerView.hidden = NO;
    self.thumbnailImageView.image = nil;
    self.thumbnailImageView.hidden = YES;
    self.sourceIconView.hidden = NO;
    self.sourceIconView.backgroundColor = self.usesVerticalLayout
        ? [UIColor clearColor]
        : [self standaloneIconBackgroundColor];
    self.contentLabel.hidden = NO;
    self.contentLabel.text = nil;
    self.sizeLabel.hidden = YES;
    self.sizeLabel.text = nil;
    self.sourceIconView.image = nil;
    [self closeSwipeActionsAnimated:NO];
    [self.pinButton setImage:[UIImage systemImageNamed:@"pin"] forState:UIControlStateNormal];
    self.pinButton.tintColor = [UIColor tertiaryLabelColor];
    [self.favoriteButton setImage:[UIImage systemImageNamed:@"star"] forState:UIControlStateNormal];
    self.favoriteButton.tintColor = [UIColor tertiaryLabelColor];
    self.deleteButton.tintColor = [UIColor systemRedColor];
    self.cardView.transform = CGAffineTransformIdentity;
    self.cardView.alpha = 1.0;
}

@end
