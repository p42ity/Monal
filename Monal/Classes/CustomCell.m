//
//  UIView.m
//  SworIM
//
//  Created by Anurodh Pokharel on 1/16/10.
//  Copyright 2010 __MyCompanyName__. All rights reserved.
//

#import "CustomCell.h"


// actual implementation of subclass
@implementation CustomCell

@synthesize text; 
@synthesize statusOrb; 


- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated
{
	
	[super setHighlighted:highlighted animated:animated];

	

	
}

- (void)setSelected:(BOOL)selected animated:(BOOL)animated
{
  //  [super setSelected:selected animated:selected];
   // [self applyLabelDropShadow:!selected];
}



- (void)layoutSubviews
{
    
    [super layoutSubviews];  //The default implementation of the layoutSubviews
    
    CGRect orbRectangle = CGRectMake(51-13+8,(self.frame.size.height/2) -7,15,15);
	statusOrb = [[UIImageView alloc] initWithFrame:orbRectangle];
    [self.contentView addSubview: statusOrb ];
    
    
    CGRect textLabelFrame = self.textLabel.frame;
    textLabelFrame.origin.x=51+13;
    textLabelFrame.size.width = self.frame.size.width-51-13-35-40;
    self.textLabel.frame = textLabelFrame;
    
    
    CGRect detailLabelFrame = self.detailTextLabel.frame;
    detailLabelFrame.origin.x=51+13;
    detailLabelFrame.size.width = self.frame.size.width-51-13-35-40;
    self.detailTextLabel.frame = detailLabelFrame;
    
    
}

- (void)drawRect:(CGRect)rect
{

    
    
    if(text==nil) return; // dont do anything.. speed up
    
	
	//debug_NSLog(@"draw in rect called"); 
	CGSize textSize = [text sizeWithFont:
					   [UIFont boldSystemFontOfSize:[UIFont systemFontSize]]
	];
	
	double capDiameter = textSize.height;
	double capRadius = capDiameter / 2.0;
	double capPadding = capDiameter / 4.0;
	double textWidth = MAX( capDiameter, textSize.width ) ;
	
	CGRect textBounds = CGRectMake(
								   capPadding,
								   0.0,
								   textWidth,
								   textSize.height
	);
	
	CGRect badgeBounds = CGRectMake(
									0.0,
									0.0,
									textWidth + (2.0 * capPadding),
									textSize.height
	);
	
	
	CGContextRef context = UIGraphicsGetCurrentContext();
	
	
	double offsetX =  CGRectGetMaxX( rect ) - 80; 
	double offsetY = CGRectGetMaxY( rect ) - CGRectGetMaxY( badgeBounds )  -15;
	

	//debug_NSLog(@"offx %d, offy %d", offsetX,offsetY); 
	
	badgeBounds = CGRectOffset( badgeBounds, offsetX, offsetY );
	textBounds = CGRectOffset( textBounds, offsetX, offsetY );
		CGContextSetRGBFillColor(context, 0.5f, 0.5f, 0.5f, 1.0f );
	
	CGContextFillEllipseInRect( context, CGRectMake(
													badgeBounds.origin.x,
													badgeBounds.origin.y,
													capDiameter,
													capDiameter
							   ) );
	
	CGContextFillEllipseInRect( context, CGRectMake(
													badgeBounds.origin.x + badgeBounds.size.width - capDiameter,
													badgeBounds.origin.y,
													capDiameter,
													capDiameter
							   ) );
	
	CGContextFillRect( context, CGRectMake(
										   badgeBounds.origin.x + capRadius,
										   badgeBounds.origin.y,
										   badgeBounds.size.width - capDiameter,
										   capDiameter
					  ) );
	

	
	
	CGContextSetFillColorWithColor(context,  [[UIColor whiteColor] CGColor]);
	
	
	[text drawInRect:textBounds
			withFont:[UIFont systemFontOfSize:12]
	   lineBreakMode:UILineBreakModeClip
		   alignment:UITextAlignmentCenter
	];
	



	
	
}
@end
