#import "TGGroupInfoUserCell.h"

#import "TGGroupInfoUserCollectionItem.h"
#import "TGGroupInfoUserCollectionItemView.h"

#import "TGPresentation.h"

@interface TGGroupInfoUserCell () {
    TGCollectionItem *_item;
    TGGroupInfoUserCollectionItemView *_itemView;
}

@end

@implementation TGGroupInfoUserCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self != nil) {
        self.selectedBackgroundView = [[UIView alloc] init];
    }
    return self;
}

- (void)setPresentation:(TGPresentation *)presentation
{
    _presentation = presentation;
    self.selectedBackgroundView.backgroundColor = presentation.pallete.selectionColor;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    
    [_item unbindView];
    [_itemView removeFromSuperview];
    _item = nil;
    _itemView = nil;
}

- (void)setItem:(TGGroupInfoUserCollectionItem *)item {
    _item = item;
    _itemView = [[TGGroupInfoUserCollectionItemView alloc] init];
    [_item bindView:_itemView];
    [self.contentView addSubview:_itemView];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    
    _itemView.frame = self.bounds;
}

@end
